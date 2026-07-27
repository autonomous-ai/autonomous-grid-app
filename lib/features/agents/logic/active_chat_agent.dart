import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../agent/agent_definition.dart';
import '../../agent/agent_registry.dart';
import '../../playground/logic/chat_sender.dart';
import 'agent_grid_support.dart';
import 'agent_status.dart';

/// The agent that answers chats right now — the user's remembered choice when
/// it's installed *and* the open grid can run it, else any agent that clears
/// both bars so chat still has one, else the catalog default.
///
/// Resolving rather than *storing* the answer is the whole point: the user's
/// pick stays in [ChatPrefs] untouched, so a grid that can't run Codex borrows
/// the chat for as long as it's open and hands it back on the next grid that
/// can. Writing the fallback into prefs would spend their choice to describe a
/// grid they were passing through.
///
/// Both bars are honest ones: an agent the user has since removed can't answer,
/// and neither can one this grid serves no model for (see [agentRunsOnGrid]).
final activeChatAgentProvider = Provider<AgentDefinition>((ref) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
  // The chosen agent, if it's one we know and it can answer here.
  final picked = agentById(chosen);
  if (picked != null && _canAnswer(ref, picked)) return picked;
  // The choice isn't available — fall back to any agent that can answer.
  for (final agent in buildAgents) {
    if (_canAnswer(ref, agent)) return agent;
  }
  return kDefaultChatAgent;
});

/// The agent the user picked and this grid can't run — null whenever their pick
/// is the one answering.
///
/// Only reported for an agent that is actually *installed*: an uninstalled pick
/// has a plainer problem, and the Agents screen already says so. Drives the
/// chat's notice, so a silent hand-over never reads as the agent behaving oddly.
final blockedChatAgentProvider = Provider<AgentDefinition?>((ref) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
  final picked = agentById(chosen);
  if (picked == null) return null;
  if (!ref.watch(agentInstalledProvider(picked.id))) return null;
  return ref.watch(agentRunsOnGridProvider(picked.id)) ? null : picked;
});

/// An agent other than the one answering that could take this chat right now —
/// installed, and runnable on the open grid.
///
/// What a one-click "use something else" offers. Null when there's nothing to
/// offer, so the button stands down rather than promising a swap that would
/// change nothing.
final alternativeChatAgentProvider = Provider<AgentDefinition?>((ref) {
  final active = ref.watch(activeChatAgentProvider);
  for (final agent in buildAgents) {
    if (agent != active && _canAnswer(ref, agent)) return agent;
  }
  return null;
});

/// Installed on this computer, and runnable on the grid that's open.
bool _canAnswer(Ref ref, AgentDefinition agent) =>
    ref.watch(agentInstalledProvider(agent.id)) &&
    ref.watch(agentRunsOnGridProvider(agent.id));

/// The [ChatSender] for whichever agent is answering chats — the seam chat
/// routing reads so it never has to know which agent is behind the reply.
final chatAgentSenderProvider = Provider<ChatSender>(
  (ref) => ref.watch(activeChatAgentProvider).sender(ref),
);
