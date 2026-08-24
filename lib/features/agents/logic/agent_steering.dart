import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_turn_part.dart';
import '../../../infrastructure/logging/app_log.dart';

/// The way into a turn that is **already running**: something the user typed
/// while the agent was working, handed to it without stopping what it is doing.
///
/// Returns null when the agent took it, else the raw reason it didn't — the
/// caller logs that (§6) and falls back to the chat's queue, so a message is
/// never simply dropped on the floor.
typedef AgentSteerChannel = Future<String?> Function(String text);

/// The chats whose running turn can be steered right now — one entry per turn
/// that has a live channel behind it, dropped the moment that turn ends.
///
/// Keyed by conversation for the same reason permissions and questions are:
/// turns run at the same time in different projects, and a message typed in one
/// chat must go to the agent answering *there*, not to whichever turn happened
/// to start last.
///
/// **This is what stops a follow-up becoming a queue** — for the one agent that
/// still has a channel to take it on:
///
/// - **Hermes** — its ACP adapter's `/steer` command, which appends the text to
///   the last tool result so the model reads it on its next iteration. The
///   current turn keeps its work and the answer that lands covers both messages.
///
/// **TODO(BE): Claude Code and Codex no longer offer one.** Both took the
/// message over the JSON channel their turn was driven on — a `user` message on
/// Claude Code's stream-json stdin, `turn/steer` on Codex's app-server — and both
/// now run in text mode, where stdin carries the prompt and is closed. A message
/// typed during their turns falls back to the queue behind it, which is what this
/// existed to stop.
///
/// Nothing here interrupts an agent — Stop is still the only thing that does.
final agentSteeringProvider =
    NotifierProvider<AgentSteeringController, Set<String>>(
      AgentSteeringController.new,
    );

/// Whether the turn running in [chatId] can be steered — what the composer
/// reads to tell "goes to the agent now" from "waits its turn".
final canSteerChatProvider = Provider.autoDispose.family<bool, String?>(
  (ref, chatId) =>
      chatId != null && ref.watch(agentSteeringProvider).contains(chatId),
);

class AgentSteeringController extends Notifier<Set<String>> {
  /// The way back to each running turn — held here rather than in the state so
  /// the UI can watch which chats are steerable without being able to reach the
  /// transport.
  final Map<String, AgentSteerChannel> _into = {};

  @override
  Set<String> build() {
    ref.onDispose(_into.clear);
    return const {};
  }

  /// [chatId]'s turn is running and will take a message — called by the sender
  /// as the turn starts.
  ///
  /// The sender's own "what has the agent seen" count is deliberately left
  /// alone: a message taken here goes into the turn's timeline, not into the
  /// transcript as a message of its own (see [TurnSaid]), so there is nothing
  /// extra for the next turn to skip.
  void offer(String chatId, AgentSteerChannel into) {
    _into[chatId] = into;
    state = Set.unmodifiable({...state, chatId});
  }

  /// [chatId]'s turn has ended: there is nobody left to steer.
  void withdraw(String chatId) {
    if (_into.remove(chatId) == null) return;
    state = Set.unmodifiable({...state}..remove(chatId));
  }

  /// Hand [text] to the turn running in [chatId]. False when there was no turn
  /// to take it, or the agent refused — the caller queues it instead.
  Future<bool> steer(String chatId, String text) async {
    final into = _into[chatId];
    if (into == null) return false;
    final refused = await into(text);
    if (refused == null) return true;
    // The user reads none of this: their message simply waits in the queue
    // instead. The raw reason is worth keeping all the same — a channel that
    // has quietly stopped working looks exactly like an agent that ignored
    // what they said.
    ref
        .read(appLogProvider)
        .failure(
          'agent',
          'The agent would not take a mid-answer message: $refused',
        );
    return false;
  }
}
