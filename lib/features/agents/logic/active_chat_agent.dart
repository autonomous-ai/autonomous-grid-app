import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import 'adapters/claude_chat_sender.dart';
import 'adapters/codex_chat_sender.dart';
import 'adapters/hermes_chat_sender.dart';
import '../../chat/logic/chat_scope.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_models.dart';
import '../../projects/logic/project.dart';
import 'agent_catalog.dart';
import 'agent_grid_support.dart';
import 'agent_model_support.dart';
import 'agent_status.dart';

/// Which agent the chats in [projectId] are meant to run — the project's own
/// pick when it has made one, else the app's standing choice ([ChatPrefs]).
///
/// A bare id, not an [AgentTool]: it's whatever was stored, including an id this
/// build no longer knows. [chatAgentForProjectProvider] is what turns it into an
/// agent that can actually answer.
final chatAgentChoiceProvider = Provider.family<String, String?>((
  ref,
  projectId,
) {
  final project = ref.watch(projectByIdProvider(projectId));
  return project?.agent ??
      ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
});

/// The agent that answers [projectId]'s chats — the choice above when it's
/// installed *and* the open grid can run it, else any agent that clears both
/// bars so chat still has one, else the catalog default.
///
/// Resolving rather than *storing* the answer is the whole point: the user's
/// pick stays where it was made (the project, or [ChatPrefs]) untouched, so a
/// grid that can't run Codex borrows the chat for as long as it's open and hands
/// it back on the next grid that can. Writing the fallback back down would spend
/// their choice to describe a grid they were passing through.
///
/// Both bars are honest ones: an agent the user has since removed can't answer,
/// and neither can one this grid serves no model for (see [agentRunsOnGrid]).
///
/// Keyed by project so a turn can be dispatched with the agent of *its own*
/// chat: a follow-up queued in one project goes out minutes later, by which time
/// the user may be reading another, and it must still be answered by the agent
/// the project it was typed in runs.
final chatAgentForProjectProvider = Provider.family<AgentTool, String?>((
  ref,
  projectId,
) {
  // The chosen agent, if it's one we know and it can answer here.
  final chosen = agentToolById(ref.watch(chatAgentChoiceProvider(projectId)));
  if (chosen != null && canAnswerChatsHere(ref, chosen)) return chosen;
  // The choice isn't available — fall back to any agent that can answer.
  for (final tool in AgentTool.values) {
    if (canAnswerChatsHere(ref, tool)) return tool;
  }
  return kChatAgent;
});

/// The agent answering the chat **on screen** — [chatAgentForProjectProvider]
/// for the project that chat belongs to.
final activeChatAgentProvider = Provider<AgentTool>(
  (ref) => ref.watch(
    chatAgentForProjectProvider(ref.watch(openChatProjectIdProvider)),
  ),
);

/// The agent the user picked for the open chat and this grid can't run — null
/// whenever their pick is the one answering.
///
/// Only reported for an agent that is actually *installed*: an uninstalled pick
/// has a plainer problem, and the Agents screen already says so. Drives the
/// chat's notice, so a silent hand-over never reads as the agent behaving oddly.
final blockedChatAgentProvider = Provider<AgentTool?>((ref) {
  final chosen = agentToolById(
    ref.watch(chatAgentChoiceProvider(ref.watch(openChatProjectIdProvider))),
  );
  if (chosen == null || !ref.watch(agentInstalledProvider(chosen))) return null;
  return ref.watch(agentRunsOnGridProvider(chosen)) ? null : chosen;
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
///
/// The one definition of "this agent could take a chat here", shared rather than
/// restated: the fallback above and the Auto agent's candidate pool both ask it,
/// and a second copy is a pool that quietly stops agreeing with the agent the
/// chat actually resolved to.
bool canAnswerChatsHere(Ref ref, AgentTool tool) =>
    ref.watch(agentInstalledProvider(tool)) &&
    ref.watch(agentRunsOnGridProvider(tool));

/// The [ChatSender] behind one agent — the seam chat routing reads so it never
/// has to know which agent is behind the reply.
///
/// Keyed by agent rather than reading "the active one" so a turn can be sent by
/// the agent that was resolved for *its* chat, even after the user has moved to
/// a project that runs a different one (see `_ChatSend.send`).
final agentChatSenderProvider = Provider.family<ChatSender, AgentTool>(
  (ref, tool) => switch (tool) {
    AgentTool.codex => ref.watch(codexChatSenderProvider),
    AgentTool.claude => ref.watch(claudeChatSenderProvider),
    AgentTool.hermes => ref.watch(hermesChatSenderProvider),
  },
);
