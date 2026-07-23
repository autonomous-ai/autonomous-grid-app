import 'context_usage.dart';

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

/// The tokens an OpenAI-shaped response says the turn cost, or null when it
/// didn't say (a `usage` block is optional, and several engines omit it).
///
/// Reads both dialects from the one place: chat completions report
/// `prompt_tokens` / `completion_tokens`, the Responses API reports
/// `input_tokens` / `output_tokens`. Their sum is what the conversation now
/// occupies — the prompt was the whole history, and the answer joins it. The
/// window itself is never in either block, so [ContextUsage.limitTokens] is
/// left for the caller to fill from what the grid advertises.
ContextUsage? extractUsage(Object? decoded) {
  if (decoded is! Map) return null;
  final usage = decoded['usage'];
  if (usage is! Map) return null;
  final input = _tokens(usage['prompt_tokens'] ?? usage['input_tokens']);
  final output = _tokens(usage['completion_tokens'] ?? usage['output_tokens']);
  if (input == null && output == null) return null;
  return ContextUsage(usedTokens: (input ?? 0) + (output ?? 0));
}

int? _tokens(Object? raw) => raw is num ? raw.toInt() : null;
