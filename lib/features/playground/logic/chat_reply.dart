import 'dart:convert';

/// Extracts the assistant's text from a chat-completion response. Both
/// `grid request chat` and the local HTTP path return OpenAI-shaped JSON; this
/// pulls out `choices[0].message.content`, falling back to `reasoning_content`
/// (reasoning models leave `content` empty mid-thought).
String extractAssistantText(Object? decoded) {
  if (decoded is! Map) return '';
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final message = (choices.first as Map)['message'];
  if (message is! Map) return '';
  final content = (message['content'] ?? '').toString().trim();
  if (content.isNotEmpty) return content;
  return (message['reasoning_content'] ?? '').toString().trim();
}

/// Parses the raw stdout of `grid request chat` for display. The CLI prints the
/// full JSON response, so return just the assistant message; falls back to the
/// raw text when it isn't the expected JSON (e.g. a plain-text or error line).
String parseChatReply(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return trimmed;
  }
  final reply = extractAssistantText(decoded);
  return reply.isNotEmpty ? reply : trimmed;
}
