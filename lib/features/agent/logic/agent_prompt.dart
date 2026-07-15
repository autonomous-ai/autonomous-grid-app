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

/// Prepends a project's standing [instructions] to the first [prompt] of a
/// session — the app's take on a repo's `AGENTS.md`, so the agent follows the
/// same house rules for everything it does in that project. Blank instructions
/// return [prompt] unchanged; only the opening turn carries them, since the
/// agent holds them in its own context for the rest of the session.
String withProjectInstructions(String prompt, String? instructions) {
  final rules = instructions?.trim() ?? '';
  if (rules.isEmpty) return prompt;
  return 'Project instructions — follow these for everything you do in this '
      'project:\n$rules\n\n$prompt';
}
