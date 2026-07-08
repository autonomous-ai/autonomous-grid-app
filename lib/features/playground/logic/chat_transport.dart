import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_reply.dart';

/// A failed chat request. [statusCode] is the HTTP status when the server
/// answered (null for transport failures — timeout, unreachable host); [message]
/// is the best human-readable reason we could extract from the body.
class ChatTransportError {
  const ChatTransportError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

/// Sends an OpenAI-style `chat/completions` request over HTTP. The seam behind
/// [chatTransportProvider] so the Playground controller can be tested with a
/// fake instead of a live relay. Both the relay path (`{relayBaseUrl}/chat/
/// completions`) and the local-engine smoke test (`{baseUrl}/v1/chat/
/// completions`) go through this — the caller passes the full [endpoint] URL.
abstract interface class ChatTransport {
  /// [messages] follows the OpenAI schema. `content` is a plain string for text
  /// turns, or a list of parts (`{type: text}` / `{type: image_url}`) when a
  /// vision turn carries attached images — hence the `dynamic` value.
  Future<(String?, ChatTransportError?)> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  });
}

/// Real [ChatTransport] over `dart:io` [HttpClient]. Non-streaming
/// (`stream: false`) — the Playground shows a single reply, not a live stream.
/// Never throws: every failure comes back as a [ChatTransportError].
class HttpChatTransport implements ChatTransport {
  const HttpChatTransport();

  @override
  Future<(String?, ChatTransportError?)> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.add(utf8.encode(jsonEncode({
        'model': model,
        'messages': messages,
        'stream': false,
      })));

      final response =
          await request.close().timeout(const Duration(seconds: 180));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        return (
          null,
          ChatTransportError(_briefError(body),
              statusCode: response.statusCode),
        );
      }
      return (extractAssistantText(jsonDecode(body)), null);
    } on TimeoutException {
      return (null, const ChatTransportError("The model didn't respond in time."));
    } on SocketException catch (e) {
      return (null, ChatTransportError("Couldn't reach the model: ${e.message}"));
    } on Object catch (e) {
      return (null, ChatTransportError("Couldn't reach the model: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// Pulls a message out of an OpenAI/FastAPI error body (`{error:{message}}` or
  /// `{detail}`), falling back to the raw text, clipped.
  static String _briefError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) return '${error['message']}';
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

/// The chat transport used by the Playground. Override in tests with a fake.
final chatTransportProvider =
    Provider<ChatTransport>((ref) => const HttpChatTransport());
