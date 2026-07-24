/// Extracts the assistant's text from an OpenAI-shaped chat-completion response
/// body: `choices[0].message.content`, falling back to `reasoning_content`
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
