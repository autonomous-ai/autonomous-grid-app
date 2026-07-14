import '../../playground/logic/chat_message.dart';

/// Builds the prompt sent to an agent CLI: the latest user turn, with any
/// earlier turns as a short context preamble so the agent isn't amnesiac between
/// messages. Shared by the codex and hermes senders so both carry context
/// identically.
String buildAgentPrompt(List<ChatMessage> history) {
  if (history.isEmpty) return '';
  final latest = history.last.text.trim();
  final prior = [
    for (final m in history.take(history.length - 1))
      if (m.text.trim().isNotEmpty)
        '${m.role == ChatRole.user ? 'User' : 'Assistant'}: ${m.text.trim()}',
  ];
  if (prior.isEmpty) return latest;
  return 'Conversation so far:\n${prior.join('\n')}\n\nUser: $latest';
}
