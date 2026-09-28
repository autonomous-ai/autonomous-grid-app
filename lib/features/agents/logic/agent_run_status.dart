import '../../chat/logic/chat_sessions_state.dart';

/// The states a chat's agent run is in, drawn the way Claude Code's VS Code
/// panel draws a session: a small dot whose colour says whether the agent is
/// working, waiting on the user, or has failed. [agent_run_indicator.dart] holds
/// the dot; this holds the *state*, so what a chat reads as can be decided (and
/// tested) without a widget.
enum AgentRunState { running, waiting, idle, unread, failed }

/// What [chatId] currently reads as, or null when it is idle — nothing at all.
///
/// Order is the precedence: a turn that failed is a failure whatever else it
/// was; a plan waiting on the user is a "needs input" wait; a send in flight is
/// running. A chat holding none of the three has no cue.
///
/// Pure, so the sidebar's decision about which dot to draw is the same decision
/// a test can assert.
AgentRunState? chatRunState(ChatSessionsState state, String chatId) {
  if (state.errors[chatId] != null) return AgentRunState.failed;
  if (state.awaitingPlanFor(chatId)) return AgentRunState.waiting;
  if (state.sendingFor(chatId) || state.runningAgents.containsKey(chatId)) {
    return AgentRunState.running;
  }
  return null;
}
