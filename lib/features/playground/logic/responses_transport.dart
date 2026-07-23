import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_message.dart';
import 'chat_reply.dart';
import 'chat_transport.dart';
import 'context_usage.dart';
import 'message_media.dart';

/// Sends an OpenAI **Responses API** request (`POST {relayBaseUrl}/responses`).
///
/// Codex subscription seats serve the `responses` endpoint *only* — a
/// `codex:*` model has no `chat/completions` provider, so a chat request to one
/// comes back `503 No providers available for this model` (ADR 0015 D-a/D-b).
/// The Playground routes those models here instead. The wire shape is the
/// vendor's Responses dialect: a top-level `instructions` (the system head) plus
/// an `input[]` array of message items whose text parts are typed `input_text`
/// (user/system) or `output_text` (prior assistant turns).
///
/// The relay passes the body through to the vendor verbatim and the vendor
/// answers over SSE, so this requests `stream: true` (and `store: false`, both
/// required by the relay) and accumulates the `response.output_text.delta`
/// events into the final reply — the Playground still shows one blocking reply,
/// so the stream is drained here rather than surfaced token by token. Never
/// throws: every failure is a [ChatTransportError].
abstract interface class ResponsesTransport {
  /// [input] is the Responses `input[]` array (see [buildResponsesInput]).
  /// [instructions] is the system head, sent as the top-level `instructions`
  /// field the Responses dialect uses in place of a `system` message.
  Future<ChatCompletion> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> input,
    String? instructions,
  });
}

/// Real [ResponsesTransport] over `dart:io` [HttpClient]. Streams the vendor SSE
/// and folds it into one string; a non-SSE JSON body (should the relay ever
/// answer non-streaming) is parsed as a fallback.
class HttpResponsesTransport implements ResponsesTransport {
  const HttpResponsesTransport();

  @override
  Future<ChatCompletion> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> input,
    String? instructions,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.add(
        utf8.encode(
          jsonEncode({
            'model': model,
            if (instructions != null && instructions.isNotEmpty)
              'instructions': instructions,
            'input': input,
            // The relay's `/responses` requires both: `stream` for the SSE body
            // we read, and `store: false` so the vendor keeps no server-side copy
            // of the response (grid never persists it either).
            'stream': true,
            'store': false,
          }),
        ),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 180),
      );
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        return (
          null,
          null,
          ChatTransportError(
            HttpChatTransport.briefError(body),
            statusCode: response.statusCode,
          ),
        );
      }
      final (text, usage) = await _readStream(response);
      return (text, usage, null);
    } on TimeoutException {
      return (
        null,
        null,
        const ChatTransportError("The model didn't respond in time."),
      );
    } on SocketException catch (e) {
      return (
        null,
        null,
        ChatTransportError("Couldn't reach the model: ${e.message}"),
      );
    } on Object catch (e) {
      return (null, null, ChatTransportError("Couldn't reach the model: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// Drains the Responses SSE body into the assistant's text and what the turn
  /// cost. Accumulates every `response.output_text.delta`; if none arrived (a
  /// non-streaming JSON body, or a terminal-only stream) it falls back to the
  /// final `response` object's `output[]`. That same terminal object carries the
  /// `usage` block — the only place in the stream it appears. Unparseable
  /// `data:` lines are skipped — a heartbeat or an event shape we don't read
  /// must not abort a live answer.
  static Future<(String, ContextUsage?)> _readStream(
    HttpClientResponse response,
  ) async {
    final deltas = StringBuffer();
    String? terminalText;
    ContextUsage? usage;

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final data = trimmed.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;

      switch (decoded['type']) {
        case 'response.output_text.delta':
          final delta = decoded['delta'];
          if (delta is String) deltas.write(delta);
        case 'response.completed':
        case 'response.incomplete':
          terminalText ??= extractResponsesText(decoded['response']);
          usage ??= extractUsage(decoded['response']);
      }
    }

    final text = deltas.isNotEmpty ? deltas.toString() : (terminalText ?? '');
    return (text, usage);
  }

  /// The assistant text inside a Responses `response` object: every
  /// `output[].content[]` part of type `output_text`, concatenated. Reasoning and
  /// tool items carry no `output_text`, so they're naturally skipped. Returns ''
  /// for any shape we can't read rather than throwing.
  static String extractResponsesText(Object? responseObject) {
    if (responseObject is! Map) return '';
    final output = responseObject['output'];
    if (output is! List) return '';
    final buffer = StringBuffer();
    for (final item in output) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is Map &&
            part['type'] == 'output_text' &&
            part['text'] is String) {
          buffer.write(part['text']);
        }
      }
    }
    return buffer.toString();
  }
}

/// Builds the Responses `input[]` array from the Playground history. User/system
/// text parts are `input_text`, prior assistant turns are `output_text` — the
/// dialect distinguishes the two, unlike chat's single `content` string. User
/// images ride as `input_image` data URIs; assistant turns carry text only.
List<Map<String, dynamic>> buildResponsesInput(
  List<ChatMessage> history,
  String? Function(String path) imageDataUri,
) {
  final items = <Map<String, dynamic>>[];
  for (final m in history) {
    final isUser = m.role == ChatRole.user;
    final parts = <Map<String, dynamic>>[
      if (m.text.isNotEmpty)
        {'type': isUser ? 'input_text' : 'output_text', 'text': m.text},
      if (isUser)
        for (final md in m.media)
          if (md.kind == MediaKind.image)
            if (imageDataUri(md.path) case final uri?)
              {'type': 'input_image', 'image_url': uri},
    ];
    if (parts.isEmpty) continue;
    items.add({'role': isUser ? 'user' : 'assistant', 'content': parts});
  }
  return items;
}

/// The Responses transport used by the Playground. Override in tests with a fake.
final responsesTransportProvider = Provider<ResponsesTransport>(
  (ref) => const HttpResponsesTransport(),
);
