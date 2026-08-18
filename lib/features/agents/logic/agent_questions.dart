import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_question.dart';
import 'agent_chat_scope.dart';

export '../../../infrastructure/cli/agent_question.dart';

/// The questions an agent has asked and nobody has answered yet, per
/// conversation.
///
/// Keyed by chat for the same reason the changes are: turns run at the same
/// time in different projects, and a question raised in one must not appear
/// over another chat's composer — the answer would go to whichever agent
/// happened to be listening there.
///
/// In memory only. A question is a live thing: it is worth answering while the
/// turn that asked it is still the last one in the chat, and reviving one from
/// a file next week would put a stale decision over a conversation that has
/// long since moved on.
final agentQuestionsProvider =
    NotifierProvider<AgentQuestions, Map<String, List<AgentQuestion>>>(
      AgentQuestions.new,
    );

/// The questions waiting in the conversation on screen — what the card shows.
/// Empty for a chat with nothing outstanding.
final openChatQuestionsProvider = Provider<List<AgentQuestion>>((ref) {
  final chatId = ref.watch(agentChatScopeProvider);
  if (chatId == null) return const [];
  return ref.watch(agentQuestionsProvider)[chatId] ?? const [];
});

class AgentQuestions extends Notifier<Map<String, List<AgentQuestion>>> {
  @override
  Map<String, List<AgentQuestion>> build() => const {};

  /// The agent working in [chatId] has asked [questions].
  ///
  /// Replaces anything outstanding rather than piling up: the agent asked again
  /// because the first set went unanswered, and two cards over one composer
  /// would leave the user answering a question the turn has already moved past.
  void ask(String chatId, List<AgentQuestion> questions) {
    if (questions.isEmpty) return;
    state = Map.unmodifiable({
      ...state,
      // Typed, not inferred: inside the map literal a bare `List.unmodifiable`
      // infers `List<dynamic>` and the map's own cast throws at runtime.
      chatId: List<AgentQuestion>.unmodifiable(questions),
    });
  }

  /// Nothing is outstanding in [chatId] any more — it was answered, waved away,
  /// or a new turn went out and overtook it.
  void clear(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = Map.unmodifiable({
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
    });
  }
}
