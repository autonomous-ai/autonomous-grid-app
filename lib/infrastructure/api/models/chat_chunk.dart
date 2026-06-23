import 'dart:convert';

/// One streamed chunk from `POST {relayBaseUrl}/chat/completions` (OpenAI
/// SSE). See CLI_Integration_Contract §4.1.
class ChatChunk {
  const ChatChunk({this.deltaContent, this.finishReason});

  final String? deltaContent;
  final String? finishReason;

  /// Parse the payload after `data: `. Returns null for the `[DONE]` sentinel
  /// or a malformed/empty chunk.
  static ChatChunk? fromSseData(String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty || trimmed == '[DONE]') return null;
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final choice = choices.first;
    if (choice is! Map) return null;
    final delta = choice['delta'];
    return ChatChunk(
      deltaContent: delta is Map ? delta['content'] as String? : null,
      finishReason: choice['finish_reason'] as String?,
    );
  }
}
