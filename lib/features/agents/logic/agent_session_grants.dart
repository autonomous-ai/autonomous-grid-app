import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What each chat has already agreed to for the rest of the conversation, so
/// "Allow in this chat" doesn't ask again — keyed by chat, then by the exact
/// thing agreed to (see `claudePermissionGrantKey`).
///
/// **The app remembers this, not the agent.** Claude Code's own way to hold a
/// grant writes rules into the project's settings file, where they outlive the
/// chat that agreed to them and apply to every later session; Hermes's
/// `allow_always` persists to its config with no way to take it back from here.
/// Neither is what "in this chat" says, so the grant lives in memory, ends with
/// the app, and is scoped to the one conversation that gave it.
final agentSessionGrantsProvider =
    NotifierProvider<AgentSessionGrants, Map<String, Set<String>>>(
      AgentSessionGrants.new,
    );

class AgentSessionGrants extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  /// Whether [chatId] has already said yes to [key] for the whole conversation.
  bool holds(String chatId, String key) =>
      state[chatId]?.contains(key) ?? false;

  void grant(String chatId, String key) {
    final held = state[chatId] ?? const <String>{};
    if (held.contains(key)) return;
    state = Map.unmodifiable({
      ...state,
      chatId: Set.unmodifiable({...held, key}),
    });
  }

  /// Forget everything [chatId] agreed to — a conversation starting fresh
  /// carries none of the last one's standing yeses.
  void clear(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = Map.unmodifiable({
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
    });
  }
}
