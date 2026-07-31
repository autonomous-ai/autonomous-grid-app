import 'dart:convert';
import 'dart:io';

import '../../features/agents/logic/connector_token.dart';
import '../../features/agents/logic/rest_entry.dart';
import 'rest_encoders.dart';

/// What one REST-backed tool call produced.
class RestResult {
  const RestResult({required this.ok, required this.text});

  final bool ok;

  /// What the agent is shown. On success the provider's own body; on failure a
  /// sentence a person can act on, never a stack trace.
  final String text;
}

/// Turns a [RestTool] plus the model's arguments into an HTTP request.
///
/// Everything provider-specific arrives in [RestEntry] — the method, the URL,
/// the header convention, the body shape. This file knows only how to fill a
/// template and send it, so a new connector is a gateway payload and not a
/// Flutter change. That constraint is the design, not an accident: the moment a
/// provider name appears in this file the architecture has failed.
class RestInvoker {
  RestInvoker({HttpClient? client, Duration? timeout})
    : _client = client ?? HttpClient(),
      _timeout = timeout ?? const Duration(seconds: 30);

  final HttpClient _client;
  final Duration _timeout;

  Future<RestResult> call({
    required RestEntry entry,
    required RestTool tool,
    required ConnectorToken token,
    required Map<String, Object?> arguments,
  }) async {
    // Required arguments are checked here rather than trusted from the model.
    // A missing `to` would otherwise reach Google as an empty header and come
    // back as a 400 nobody can interpret.
    final missing = [
      for (final entry in tool.params.entries)
        if (entry.value.required &&
            (arguments[entry.key] == null ||
                '${arguments[entry.key]}'.trim().isEmpty))
          entry.key,
    ];
    if (missing.isNotEmpty) {
      return RestResult(
        ok: false,
        text:
            'Missing required ${missing.length == 1 ? 'argument' : 'arguments'}: '
            '${missing.join(', ')}.',
      );
    }

    if (entry.auth.location != 'header') {
      // Refuse rather than guess. Putting a credential somewhere the provider
      // did not ask for it is worse than a tool that says it cannot run.
      return RestResult(
        ok: false,
        text:
            'This connector needs a credential placed somewhere this version '
            'of Grid does not support ("${entry.auth.location}").',
      );
    }

    final Uri uri;
    final Object? body;
    try {
      uri = _buildUri(tool.request, arguments);
      body = tool.request.json == null
          ? null
          : _fill(tool.request.json, arguments);
    } on RestEncoderException catch (error) {
      return RestResult(ok: false, text: error.toString());
    } on Object catch (error) {
      return RestResult(ok: false, text: "Couldn't build the request: $error");
    }

    try {
      final request = await _client.openUrl(tool.request.method, uri);
      request.headers.set(
        entry.auth.name,
        _substitute(entry.auth.format, {
          'access_token': token.accessToken,
          'token_type': token.tokenType,
        }),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final upload = tool.request.multipart;
      if (upload != null) {
        final boundary = 'grid-${DateTime.now().microsecondsSinceEpoch}';
        request.headers.contentType = ContentType(
          'multipart',
          'related',
          parameters: {'boundary': boundary},
        );
        request.add(
          utf8.encode(_multipartBody(boundary, _fill(upload, arguments))),
        );
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return RestResult(ok: true, text: text.isEmpty ? '{}' : text);
      }
      return RestResult(
        ok: false,
        text: _failureSentence(response.statusCode, text),
      );
    } on Object catch (error) {
      // The message, not the object: an HttpException's toString carries the
      // full URI, and a query-parameter credential would ride out with it.
      return RestResult(
        ok: false,
        text: "Couldn't reach the provider (${error.runtimeType}).",
      );
    }
  }

  /// A status a person can act on.
  ///
  /// 401 and 403 are separated because they mean opposite things to the user:
  /// the credential lapsed and the app will fix it, versus the account was never
  /// allowed to do this and only reconnecting with more permission will. Gmail
  /// is exactly the second case and reading it as the first sends people around
  /// a reconnect loop that cannot help.
  String _failureSentence(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'The connection needs signing in again$detail',
      403 =>
        "This account doesn't have permission for that. Reconnect the "
            'connector and grant the extra access$detail',
      // Deliberately about the *thing*, not the URL. A 404 here is almost
      // always an id the model guessed or mistyped — a Figma file key, a Drive
      // file id — and "the provider has no such endpoint" sent the reader
      // looking for a bug in Grid instead of at the identifier they passed.
      404 => 'Not found — check the id or key that was used$detail',
      429 =>
        'The provider is rate-limiting this account. Try again shortly$detail',
      _ when status >= 500 => 'The provider had an error ($status)$detail',
      _ => 'The provider refused the request ($status)$detail',
    };
  }

  /// Pull the provider's own explanation out, when it gave one.
  String _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        final message = error is Map
            ? error['message']
            : (decoded['message'] ?? decoded['detail']);
        if (message is String && message.isNotEmpty) return ': $message';
      }
    } on Object {
      // Not JSON. The status alone is still useful, and echoing an HTML error
      // page into a chat helps nobody.
    }
    return '.';
  }

  /// RFC 2387 `multipart/related`: a JSON metadata part, then the content.
  ///
  /// Two parts and no more, because that is the whole of what an upload of this
  /// shape needs and every extra degree of freedom here is a way for a payload
  /// to describe a request nobody can debug. CRLF throughout — the spec says
  /// so, and a bare LF is the kind of thing one server accepts and the next
  /// rejects.
  String _multipartBody(String boundary, Object? filled) {
    final parts = filled is Map ? filled : const {};
    final metadata = parts['metadata'] ?? const <String, Object?>{};
    final content = parts['content'];
    final contentType = parts['content_type'];
    return '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode(metadata)}\r\n'
        '--$boundary\r\n'
        'Content-Type: ${contentType is String && contentType.isNotEmpty ? contentType : 'text/plain'}\r\n\r\n'
        '${content is String ? content : ''}\r\n'
        '--$boundary--';
  }

  Uri _buildUri(RestRequest request, Map<String, Object?> arguments) {
    // Percent-encoded, because a value substituted into the *path* is the one
    // place an argument can change the shape of the request rather than its
    // content: `../../` or a bare `?` would otherwise walk to a different
    // endpoint entirely. These arguments are filled in by a language model from
    // a sentence, so they are untrusted by construction. Query values are left
    // alone — `Uri.replace` encodes those itself, and double-encoding would
    // send `%2540`.
    final url = _substitute(request.url, arguments, urlSafe: true);
    final uri = Uri.parse(url);
    if (request.query.isEmpty) return uri;
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        for (final entry in request.query.entries)
          // An optional parameter the model left out must be *absent*, not
          // empty. `timeMin=` is a 400 from Google; no `timeMin` at all is the
          // documented default. Required ones were already checked in [call].
          if (_substitute(entry.value, arguments).isNotEmpty)
            entry.key: _substitute(entry.value, arguments),
      },
    );
  }

  /// Walk a body template, substituting `{name}` and running named encoders.
  Object? _fill(Object? template, Map<String, Object?> arguments) {
    if (template is String) return _substitute(template, arguments);
    if (template is List) {
      return [for (final item in template) _fill(item, arguments)];
    }
    if (template is Map) {
      final encoder = template[r'$encode'];
      if (encoder is String) {
        // The encoder's inputs are the sibling keys, already substituted.
        final fields = <String, Object?>{
          for (final entry in template.entries)
            if (entry.key != r'$encode')
              '${entry.key}': _fill(entry.value, arguments),
        };
        return applyRestEncoder(encoder, fields);
      }
      return {
        for (final entry in template.entries)
          '${entry.key}': _fill(entry.value, arguments),
      };
    }
    return template;
  }

  /// Replace `{name}` with the argument of that name.
  ///
  /// A placeholder with no argument becomes empty rather than staying literal:
  /// an optional parameter left out must not send the provider the four
  /// characters `{cc}`.
  String _substitute(
    String template,
    Map<String, Object?> arguments, {
    bool urlSafe = false,
  }) => template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) {
    final value = arguments[match.group(1)];
    if (value == null) return '';
    return urlSafe ? Uri.encodeComponent('$value') : '$value';
  });

  void close() => _client.close(force: true);
}
