import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import 'adapters/claude_chat_sender.dart';
import 'adapters/codex_chat_sender.dart';
import 'adapters/hermes_chat_sender.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_models.dart';
import 'agent_catalog.dart';
import 'agent_grid_support.dart';
import 'agent_model_support.dart';
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
final activeChatAgentProvider = Provider<AgentTool>((ref) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
  // The chosen agent, if it's one we know and it can answer here.
  for (final tool in AgentTool.values) {
    if (tool.id == chosen && _canAnswer(ref, tool)) return tool;
  }
  // The choice isn't available — fall back to any agent that can answer.
  for (final tool in AgentTool.values) {
    if (_canAnswer(ref, tool)) return tool;
  }
  return kChatAgent;
});

/// The agent the user picked and this grid can't run — null whenever their pick
/// is the one answering.
///
/// Only reported for an agent that is actually *installed*: an uninstalled pick
/// has a plainer problem, and the Agents screen already says so. Drives the
/// chat's notice, so a silent hand-over never reads as the agent behaving oddly.
final blockedChatAgentProvider = Provider<AgentTool?>((ref) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
  for (final tool in AgentTool.values) {
    if (tool.id != chosen) continue;
    if (!ref.watch(agentInstalledProvider(tool))) return null;
    return ref.watch(agentRunsOnGridProvider(tool)) ? null : tool;
  }
  return null;
});

/// An agent other than the one answering that could take this chat right now —
/// installed, and runnable on the open grid.
///
/// What a one-click "use something else" offers. Null when there's nothing to
/// offer, so the button stands down rather than promising a swap that would
/// change nothing.
final alternativeChatAgentProvider = Provider<AgentTool?>((ref) {
  final active = ref.watch(activeChatAgentProvider);
  for (final tool in AgentTool.values) {
    if (tool != active && _canAnswer(ref, tool)) return tool;
  }
  return null;
});

/// Whether the open grid serves a model [tool] could actually answer with — the
/// model half of "can this agent take the chat here", beside
/// [agentRunsOnGridProvider]'s grid half.
///
/// An empty list is "the grid hasn't answered yet", never "nothing to use":
/// reading it as no would flash "no model it can use" on every grid switch, and
/// a grid that really serves nothing has its own screen for that.
final agentHasModelHereProvider = Provider.autoDispose.family<bool, AgentTool>((
  ref,
  tool,
) {
  final options = ref.watch(playgroundModelsProvider);
  if (options.isEmpty) return true;
  return options.any((option) => agentSupportsModel(tool, option.id));
});

/// The agent whose model requirements the composer has to respect — null when
/// no agent is installed at all.
///
/// Null is not "none of them": it's "nothing stands between the chat and the
/// grid". Without an agent the chat posts to the relay itself, which serves
/// every model it lists, so filtering the picker by an agent that isn't there
/// would grey out models that answer perfectly well.
final chatModelAgentProvider = Provider<AgentTool?>(
  (ref) => ref.watch(anyAgentInstalledProvider)
      ? ref.watch(activeChatAgentProvider)
      : null,
);

/// Installed on this computer, and runnable on the grid that's open.
bool _canAnswer(Ref ref, AgentTool tool) =>
    ref.watch(agentInstalledProvider(tool)) &&
    ref.watch(agentRunsOnGridProvider(tool));

/// The [ChatSender] for whichever agent is answering chats — the seam chat
/// routing reads so it never has to know which agent is behind the reply.
final chatAgentSenderProvider = Provider<ChatSender>((ref) {
  return switch (ref.watch(activeChatAgentProvider)) {
    AgentTool.codex => ref.watch(codexChatSenderProvider),
    AgentTool.claude => ref.watch(claudeChatSenderProvider),
    AgentTool.hermes => ref.watch(hermesChatSenderProvider),
  };
});
