import 'dart:convert';
import 'dart:io';

import '../../features/agents/logic/connector_token.dart';

/// What one proxied JSON-RPC round trip produced.
class McpProxyResult {
  const McpProxyResult({required this.body, this.sessionId});

  /// The provider's JSON-RPC object, ready to be handed back to the agent
  /// verbatim. On failure this is a JSON-RPC `error` object built here.
  final Map<String, Object?> body;

  /// The provider's `Mcp-Session-Id`, when it issued one.
  final String? sessionId;
}

/// Forwards JSON-RPC to a connector's real MCP server, attaching the credential.
///
/// **Why this exists.** A connector whose `mcp_entry` carries an `Authorization`
/// header can only be handed to an agent by writing that header into the agent's
/// config file — which is rule 5's exact prohibition, and the D17 debt for the
/// one agent that does it. Every other agent refuses, so the whole of path A
/// (self-registration, 24 bundled connectors, any typed URL) reached exactly one
/// agent. Proxying moves the credential back to where it belongs: the app holds
/// it, attaches it per request, and the agent is given a loopback address that
/// carries nothing.
///
/// **Why it is a forwarder and not a translator.** Unlike [RestInvoker], which
/// has to *build* an MCP surface out of a REST API, both ends here already speak
/// JSON-RPC. The request body travels unchanged; only the transport headers are
/// this file's business. That is deliberate — anything this file decided about
/// method names or arguments would be a second, divergent MCP implementation.
///
/// **Two response shapes, measured 2026-08-03 against live servers.** The spec
/// lets a streamable-HTTP server answer either way and both are in use:
///
/// ```
/// mcp.canva.com          → content-type: application/json     (no session id)
/// api.githubcopilot.com  → content-type: text/event-stream     + Mcp-Session-Id
/// ```
///
/// Neither is a long-lived stream: the SSE answer is one `event: message` whose
/// `data:` line holds the whole response, and the connection closes. So this
/// reads the body to completion and unwraps it — no streaming machinery, which
/// was the risk this design was checked for before being chosen.
class McpProxy {
  McpProxy({HttpClient? client, Duration? timeout})
    : _client = client ?? HttpClient(),
      _timeout = timeout ?? const Duration(seconds: 60);

  final HttpClient _client;
  final Duration _timeout;

  /// Both content types, always.
  ///
  /// Not a preference — a requirement of the streamable-HTTP transport, and one
  /// that is enforced: Canva answers `406 Not Acceptable` to a request naming
  /// only `application/json`, with the reason spelled out in the body. Sending
  /// both lets the server pick, which is the point of the negotiation.
  static const _accept = 'application/json, text/event-stream';

  /// Send [payload] to [entry]'s server as [token]'s owner.
  ///
  /// [sessionId] is the one the agent's session already established, when there
  /// is one; the provider's reply may carry a new one, which the caller should
  /// remember and send next time.
  Future<McpProxyResult> forward({
    required McpEntry entry,
    required ConnectorToken token,
    required Map<String, Object?> payload,
    String? sessionId,
  }) async {
    try {
      final request = await _client.postUrl(Uri.parse(entry.url));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, _accept);

      // The credential, attached here and nowhere else. `entry.headers` is what
      // the projection used to write into a config file; keeping it in the app
      // and spending it per request is the whole point of the detour.
      entry.headers.forEach(request.headers.set);
      if (sessionId != null) request.headers.set('Mcp-Session-Id', sessionId);

      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();
      final session = response.headers.value('mcp-session-id') ?? sessionId;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return McpProxyResult(
          body: _error(
            payload['id'],
            _failureSentence(response.statusCode, text),
          ),
          sessionId: session,
        );
      }

      final decoded = _decode(text, response.headers.contentType?.mimeType);
      if (decoded == null) {
        return McpProxyResult(
          body: _error(
            payload['id'],
            'The connector returned a reply this app could not read.',
          ),
          sessionId: session,
        );
      }
      return McpProxyResult(body: decoded, sessionId: session);
    } on Object catch (error) {
      // The type, not the object: an HttpException's `toString` carries the full
      // URI, and this one is reached with a credential in the headers.
      return McpProxyResult(
        body: _error(
          payload['id'],
          "Couldn't reach the connector (${error.runtimeType}).",
        ),
      );
    }
  }

  void close() => _client.close(force: true);

  /// The JSON-RPC object inside a reply, whichever shape it arrived in.
  ///
  /// The mime type decides, with a fallback for a server that mislabels: a body
  /// starting `event:`/`data:` is SSE whatever it claims, and one that parses as
  /// JSON is JSON. Guessing from the content alone was tempting and wrong —
  /// `data:` can legitimately open a JSON string value.
  Map<String, Object?>? _decode(String text, String? mimeType) {
    final looksSse =
        mimeType == 'text/event-stream' ||
        text.trimLeft().startsWith('event:') ||
        text.trimLeft().startsWith('data:');
    final payload = looksSse ? _lastDataLine(text) : text;
    if (payload == null || payload.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  /// The final `data:` payload in an SSE body.
  ///
  /// **The last, not the first.** A server may send progress notifications
  /// before the answer, and those are `data:` lines too; the response to the
  /// request is the one that arrives last. Continuation lines are joined,
  /// because SSE allows a single event's data to span several `data:` lines and
  /// a large `tools/list` is exactly where that shows up.
  String? _lastDataLine(String text) {
    final events = <List<String>>[];
    var current = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        if (current.isNotEmpty) events.add(current);
        current = <String>[];
        continue;
      }
      if (line.startsWith('data:')) {
        current.add(line.substring(5).trimLeft());
      }
    }
    if (current.isNotEmpty) events.add(current);
    if (events.isEmpty) return null;
    return events.last.join('\n');
  }

  /// A JSON-RPC error the agent can relay, carrying the request's own id.
  ///
  /// `-32603` (internal error) rather than a transport code: from the agent's
  /// side this *is* the server, and inventing codes it would have to learn is
  /// worse than the one the spec reserves for "something went wrong in here".
  Map<String, Object?> _error(Object? id, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32603, 'message': message},
  };

  /// The same readings [RestInvoker] gives, for the same reason: 401 and 403
  /// mean opposite things to the person reading them.
  String _failureSentence(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'The connection needs signing in again$detail',
      403 =>
        "This account doesn't have permission for that. Reconnect the "
            'connector and grant the extra access$detail',
      404 => 'The connector\'s server is not answering at that address$detail',
      406 =>
        'The connector refused the request format. This is a bug in Grid, not '
            'in your account$detail',
      429 =>
        'The provider is rate-limiting this account. Try again shortly$detail',
      _ when status >= 500 => 'The provider had an error ($status)$detail',
      _ => 'The provider refused the request ($status)$detail',
    };
  }

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
      // Not JSON — an SSE frame or an HTML error page. The status alone still
      // reads, and echoing a page into a chat helps nobody.
    }
    return '.';
  }
}
