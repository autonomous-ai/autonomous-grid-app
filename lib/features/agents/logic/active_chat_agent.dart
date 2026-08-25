import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import 'adapters/claude_chat_sender.dart';
import 'adapters/codex_chat_sender.dart';
import 'adapters/hermes_chat_sender.dart';
import '../../chat/logic/chat_scope.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
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

/// The agent a stored choice actually resolves to — [choice] when it names an
/// agent that is installed *and* the open grid can run, else any agent that
/// clears both bars so chat still has one, else the catalog default.
///
/// Resolving rather than *storing* the answer is the whole point: the user's
/// pick stays where it was made (the chat, the project, or [ChatPrefs])
/// untouched, so a grid that can't run Codex borrows the chat for as long as
/// it's open and hands it back on the next grid that can. Writing the fallback
/// back down would spend their choice to describe a grid they were passing
/// through.
///
/// Both bars are honest ones: an agent the user has since removed can't answer,
/// and neither can one this grid serves no model for (see [agentRunsOnGrid]).
///
/// Keyed by the choice rather than by where it was read from, so the one
/// resolution serves all three readers — a chat that fixed its own agent, a
/// project, and the app's standing pick — instead of each growing a copy that
/// drifts.
final resolvedChatAgentProvider = Provider.family<AgentTool, String?>((
  ref,
  choice,
) {
  // The chosen agent, if it's one we know and it can answer here.
  final chosen = agentToolById(choice);
  if (chosen != null && canAnswerChatsHere(ref, chosen)) return chosen;
  // The choice isn't available — fall back to any agent that can answer.
  for (final tool in AgentTool.values) {
    if (canAnswerChatsHere(ref, tool)) return tool;
  }
  return kChatAgent;
});

/// The agent that answers [projectId]'s chats — its standing pick, resolved.
///
/// Keyed by project so a turn can be dispatched with the agent of *its own*
/// chat: a follow-up queued in one project goes out minutes later, by which time
/// the user may be reading another, and it must still be answered by the agent
/// the project it was typed in runs.
///
/// This is the pick a **new** chat there will start on. A chat already under way
/// answers with the agent it fixed at its first message — see
/// [openChatAgentChoiceProvider], and `Conversation.agent` for why a session
/// keeps its own.
final chatAgentForProjectProvider = Provider.family<AgentTool, String?>(
  (ref, projectId) => ref.watch(
    resolvedChatAgentProvider(ref.watch(chatAgentChoiceProvider(projectId))),
  ),
);

/// The agent the chat **on screen** fixed when it started, or null while it
/// hasn't started one (a blank compose, or a chat saved before sessions pinned
/// theirs).
final openChatAgentPinProvider = Provider<String?>(
  (ref) => ref.watch(chatSessionsProvider.select((s) => s.active?.agent)),
);

/// Whether the chat on screen has settled its agent — the picker shows it as a
/// fact rather than offering a menu.
///
/// True from the moment a chat starts, which is one of two things: it was born
/// with its agent written down, or it has a message in it. The second half is
/// what covers a chat saved before this existed — it is plainly under way, and
/// its next message pins the agent it is already answering with.
final chatAgentLockedProvider = Provider<bool>(
  (ref) => ref.watch(
    chatSessionsProvider.select((s) {
      final chat = s.active;
      return chat != null && (chat.agent != null || chat.messages.isNotEmpty);
    }),
  ),
);

/// The choice in force for the chat **on screen**: its own, once it has fixed
/// one, else the standing pick of the project it sits in (or the app's).
final openChatAgentChoiceProvider = Provider<String?>(
  (ref) =>
      ref.watch(openChatAgentPinProvider) ??
      ref.watch(chatAgentChoiceProvider(ref.watch(openChatProjectIdProvider))),
);

/// The agent answering the chat **on screen**.
final activeChatAgentProvider = Provider<AgentTool>(
  (ref) => ref.watch(
    resolvedChatAgentProvider(ref.watch(openChatAgentChoiceProvider)),
  ),
);

/// The agent the **next** chat in the open scope will start on — the project's
/// standing pick, or the app's.
///
/// Sibling to [activeChatAgentProvider] and deliberately not the same question.
/// Anything describing the *setting* — the Agents screen's "Answers new chats",
/// which is also where tapping a card writes the pick — has to read this one, or
/// a chat that fixed a different agent would leave the screen unable to show the
/// choice its own tap just saved.
final scopeChatAgentProvider = Provider<AgentTool>(
  (ref) => ref.watch(
    chatAgentForProjectProvider(ref.watch(openChatProjectIdProvider)),
  ),
);

/// The agent behind [chat], for anything that only needs to **name** it.
///
/// Three answers, in order of how directly each was written down: the agent the
/// chat fixed when it started ([Conversation.agent]); the one that signed its
/// last reply; the one holding a session it can resume. The second and third
/// are what a chat saved before agents were written down has left — and they
/// are not redundant with each other, because a chat shown as a terminal
/// commits no replies at all while a chat Hermes answered keeps no session.
///
/// Null when none of them answers: a chat the grid replied to directly, with no
/// agent between it and the relay.
///
/// Not a stand-in for [activeChatAgentProvider]: this reports what a chat *is*,
/// with no view on whether that agent is installed or runnable on the grid that
/// happens to be open. Right for a row in a list, wrong for dispatching a turn.
AgentTool? agentOfChat(Conversation chat) =>
    agentToolById(chat.agent) ??
    agentOfLastReply(chat) ??
    (chat.resume.isEmpty ? null : agentToolById(chat.resume.first.agent));

/// The agent that wrote [chat]'s most recent reply, or null when the last one
/// came from the grid itself (no agent stamp) or from an agent this build no
/// longer ships.
///
/// Read off the transcript rather than remembered in a field: the stamp is
/// already persisted with the reply, so approving a plan still continues the
/// right agent after a restart, and a chat that has never had an agent reply
/// falls back to being routed like any other.
AgentTool? agentOfLastReply(Conversation chat) {
  for (final message in chat.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    return agentToolById(message.agent);
  }
  return null;
}

/// The agent the open chat is meant to run and this grid can't — null whenever
/// its choice is the one answering.
///
/// Only reported for an agent that is actually *installed*: an uninstalled pick
/// has a plainer problem, and the Agents screen already says so. Drives the
/// chat's notice, so a silent hand-over never reads as the agent behaving oddly.
final blockedChatAgentProvider = Provider<AgentTool?>((ref) {
  final chosen = agentToolById(ref.watch(openChatAgentChoiceProvider));
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
