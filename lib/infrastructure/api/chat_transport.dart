import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_reply.dart';

/// One event from a streaming chat completion: text as it arrives, a clean
/// finish, or a failure. A sealed type so the caller switches exhaustively
/// instead of juggling nullable text/error.
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

/// The next slice of the assistant's reply — a delta, not the whole thing so
/// far. The caller accumulates.
class ChatDelta extends ChatStreamEvent {
  const ChatDelta(this.text);
  final String text;
}

/// The reply finished cleanly; whatever deltas arrived are the whole answer.
class ChatDone extends ChatStreamEvent {
  const ChatDone();
}

/// The request failed. Terminates the stream — no [ChatDone] follows.
class ChatFailed extends ChatStreamEvent {
  const ChatFailed(this.error);
  final ChatTransportError error;
}

/// What a one-shot completion came back with: the assistant's text and the
/// failure — exactly one is meaningful. Kept for callers that only want the
/// finished reply (a skill generation), via [ChatTransportComplete.complete].
typedef ChatCompletion = (String?, ChatTransportError?);

/// A failed chat request. [statusCode] is the HTTP status when the server
/// answered (null for transport failures — timeout, unreachable host); [message]
/// is the best human-readable reason we could extract from the body.
class ChatTransportError {
  const ChatTransportError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

/// Sends an OpenAI-style `chat/completions` request over HTTP and streams the
/// reply back token by token. The seam behind [chatTransportProvider] so the
/// chat controllers can be tested with a fake instead of a live relay. Both the
/// relay path (`{relayBaseUrl}/chat/completions`) and the local-engine smoke
/// test (`{baseUrl}/v1/chat/completions`) go through this — the caller passes
/// the full [endpoint] URL.
abstract interface class ChatTransport {
  /// [messages] follows the OpenAI schema. `content` is a plain string for text
  /// turns, or a list of parts (`{type: text}` / `{type: image_url}`) when a
  /// vision turn carries attached images — hence the `dynamic` value.
  ///
  /// Never throws: every failure arrives as a terminal [ChatFailed].
  ///
  /// [conversationId], when non-null and non-empty, rides as the
  /// `X-Grid-Conversation` header — the relay's hook for attributing which
  /// model(s) answered a given conversation turn. Null for callers with no
  /// conversation of their own (a one-off skill generation, the Playground).
  ///
  /// [turnId], when non-null and non-empty, rides as the `X-Request-Id` header
  /// — the per-turn id the app stamps so `/usage/turn/{id}` can count exactly
  /// what served that one turn. Same null rule.
  Stream<ChatStreamEvent> stream({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
    String? turnId,
  });
}

/// Drains a streaming transport into a single reply, for callers that don't
/// show the text arriving — a one-shot skill generation, say. On an interface
/// rather than each implementation so a fake never has to reimplement it.
extension ChatTransportComplete on ChatTransport {
  Future<ChatCompletion> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final buffer = StringBuffer();
    await for (final event in stream(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      messages: messages,
    )) {
      switch (event) {
        case ChatDelta(:final text):
          buffer.write(text);
        case ChatFailed(:final error):
          return (null, error);
        case ChatDone():
          break;
      }
    }
    return (buffer.toString(), null);
  }
}

/// Real [ChatTransport] over `dart:io` [HttpClient]. Requests `stream: true` and
/// folds the SSE `choices[].delta.content` chunks into [ChatDelta]s; a relay
/// that answers with a plain (non-streamed) JSON body is handled too, yielding
/// its whole `message.content` as one delta. Never throws — every failure is a
/// terminal [ChatFailed].
class HttpChatTransport implements ChatTransport {
  const HttpChatTransport();

  @override
  Stream<ChatStreamEvent> stream({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
    String? turnId,
  }) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      if (conversationId != null && conversationId.isNotEmpty) {
        request.headers.set('X-Grid-Conversation', conversationId);
      }
      if (turnId != null && turnId.isNotEmpty) {
        request.headers.set('X-Request-Id', turnId);
      }
      request.add(
        utf8.encode(
          jsonEncode(chatCompletionsPayload(model: model, messages: messages)),
        ),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 180),
      );
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        yield ChatFailed(
          ChatTransportError(briefError(body), statusCode: response.statusCode),
        );
        return;
      }

      // A `data:`-prefixed line is an SSE chunk; anything else means the relay
      // ignored `stream` and sent a whole JSON body, which is buffered and
      // parsed once the response ends (see [_flushWholeBody]).
      final whole = StringBuffer();
      var sawStream = false;
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) {
          whole.write(line);
          continue;
        }
        sawStream = true;
        final data = trimmed.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final delta = chatStreamDelta(data);
        if (delta != null && delta.isNotEmpty) yield ChatDelta(delta);
      }

      if (!sawStream) {
        final text = chatStreamWholeBody(whole.toString());
        if (text.isNotEmpty) yield ChatDelta(text);
      }
      yield const ChatDone();
    } on TimeoutException {
      yield const ChatFailed(
        ChatTransportError("The model didn't respond in time."),
      );
    } on SocketException catch (e) {
      yield ChatFailed(
        ChatTransportError("Couldn't reach the model: ${e.message}"),
      );
    } on Object catch (e) {
      yield ChatFailed(ChatTransportError("Couldn't reach the model: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// Pulls a message out of an OpenAI/FastAPI error body (`{error:{message}}` or
  /// `{detail}`), falling back to the raw text, clipped. Public so the Responses
  /// transport, whose error envelope is the same `{detail}` shape, reuses it.
  static String briefError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          return '${error['message']}';
        }
        if (error != null) return '$error';
        final detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      }
    } on Object {
      // Non-JSON error body — fall through to the raw text.
    }
    final trimmed = body.trim();
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
  }
}

/// The `chat/completions` request body. Pure, and the single definition of the
/// payload: the Debug tab records what a call sent, and a body hand-written a
/// second time for the log is a body that quietly stops matching the wire.
Map<String, dynamic> chatCompletionsPayload({
  required String model,
  required List<Map<String, dynamic>> messages,
}) => {'model': model, 'messages': messages, 'stream': true};

/// The chat transport used by the Playground and the Chat tab. Override in tests
/// with a fake.
final chatTransportProvider = Provider<ChatTransport>(
  (ref) => const HttpChatTransport(),
);

/// The text a single SSE chunk carries: `choices[0].delta.content`. Null for a
/// chunk with no text to add — a role-only opener, a `finish_reason` tail, a
/// heartbeat, or a shape we don't read — so one such line is skipped, never
/// aborting a live answer. Pure, so the SSE parsing is unit-tested off a live
/// relay.
String? chatStreamDelta(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is! Map) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final delta = (choices.first as Map)['delta'];
    if (delta is! Map) return null;
    final content = delta['content'];
    return content is String ? content : null;
  } on FormatException {
    return null;
  }
}

/// A relay that ignored `stream: true` and sent one JSON body — parsed the same
/// way the non-streaming path did (`choices[0].message.content`), so a relay
/// that doesn't stream still answers. Empty for a body that isn't a completion.
String chatStreamWholeBody(String body) {
  if (body.trim().isEmpty) return '';
  try {
    return extractAssistantText(jsonDecode(body));
  } on FormatException {
    return '';
  }
}
