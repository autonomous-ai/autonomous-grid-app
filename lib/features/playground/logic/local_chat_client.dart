import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'chat_reply.dart';

/// Direct OpenAI-style call to a locally-running provider (llama.cpp server),
/// bypassing the relay — the same request the `curl http://localhost:PORT/v1/
/// chat/completions` smoke test makes. Used by the Playground's "Test local"
/// switch. Returns `(reply, null)` on success or `(null, error)` on failure;
/// it never throws.
class LocalChatClient {
  const LocalChatClient._();

  static Future<(String?, String?)> complete({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request =
          await client.postUrl(Uri.parse('$baseUrl/v1/chat/completions'));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (apiKey.isNotEmpty) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
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
        return (null, 'Error ${response.statusCode}: ${_briefError(body)}');
      }
      return (extractAssistantText(jsonDecode(body)), null);
    } on TimeoutException {
      return (null, "Your model didn't respond in time (180s).");
    } on SocketException catch (e) {
      return (null, "Couldn't reach your model: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't reach your model: $e");
    } finally {
      client.close(force: true);
    }
  }

  static String _briefError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) {
        final error = decoded['error'];
        return error is Map ? '${error['message'] ?? error}' : '$error';
      }
    } on Object {
      // Non-JSON error body — fall through to the raw text.
    }
    final trimmed = body.trim();
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
  }
}
