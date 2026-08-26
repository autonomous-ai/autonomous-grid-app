import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import 'active_chat_agent.dart';
import 'agent_catalog.dart';

/// How a chat with [tool] is drawn, given the choice made for it.
///
/// Pure, and the single place the rule lives, because three callers ask it of
/// three different [chosen]s — the setting (a chat about to start), the chat's
/// own record (one already under way), and nothing at all (a chat saved before
/// either existed). A copy per caller is how the composer and the transcript
/// would come to disagree about which surface a chat is in, and the symptom of
/// that is a conversation that isn't on screen.
///
/// An agent with no interactive CLI has no choice to make: Hermes speaks ACP,
/// there is no program to draw, and offering the option would be offering
/// something that cannot happen (§5).
///
/// [chosen] null falls to the agent's own default — the terminal for the two
/// that have one. **Deliberately not the setting**: a chat that recorded no
/// surface is one that started before the setting existed, and reading the live
/// value there would take a running terminal chat's conversation off screen the
/// moment someone changed their mind about the *next* chat.
AgentChatSurface agentChatSurface(AgentTool tool, {AgentChatSurface? chosen}) {
  if (!tool.hasInteractiveCli) return AgentChatSurface.list;
  return chosen ?? AgentChatSurface.terminal;
}

/// The surface a **new** chat with [tool] will start in — the user's setting for
/// that agent, or the agent's default until they change it.
final agentChatSurfaceProvider = Provider.family<AgentChatSurface, AgentTool>((
  ref,
  tool,
) {
  final chosen = ref.watch(
    chatPrefsProvider.select((p) => p.agentSurface[tool.id]),
  );
  return agentChatSurface(tool, chosen: chosen);
});

/// The surface the chat **on screen** is drawn in.
///
/// A chat draws the way it was drawn when it started: the surface is written
/// down at birth beside the agent (`Conversation.surface`), for the same reason
/// the agent is — from the first message the chat is a session, and the setting
/// belongs to the next chat rather than to this one.
final openChatSurfaceProvider = Provider<AgentChatSurface>((ref) {
  final tool = ref.watch(activeChatAgentProvider);
  final open = ref.watch(
    chatSessionsProvider.select(
      (s) => (started: s.active != null, surface: s.active?.surface),
    ),
  );
  // Nothing open: what is in front of the user is a composer, and pressing Send
  // starts a chat the setting decides the shape of.
  if (!open.started) return ref.watch(agentChatSurfaceProvider(tool));
  return agentChatSurface(tool, chosen: open.surface);
});

/// Whether the chat on screen is drawn as its agent's own terminal.
///
/// The same question as [openChatSurfaceProvider], asked the way its readers
/// ask it: the chat screen decides three things off this one yes/no — what Send
/// does, where a dropped file goes, and which pane is drawn — and spelling the
/// comparison out three times is three chances to spell it differently.
final openChatInTerminalProvider = Provider<bool>(
  (ref) => ref.watch(openChatSurfaceProvider) == AgentChatSurface.terminal,
);

/// The control's name for each surface.
String agentChatSurfaceLabel(AgentChatSurface surface) => switch (surface) {
  AgentChatSurface.list => 'Messages',
  AgentChatSurface.terminal => 'Terminal',
};

/// What picking it actually changes, in one line under the control.
///
/// Both surfaces stop and ask before the assistant runs a command or changes a
/// file — they differ in **who does the asking**, not in whether anyone does.
/// The list asks with the app's own card; the terminal asks in the CLI's words
/// and takes the answer from the keyboard. Copy must not imply the quieter
/// option is the looser one: it isn't, and a user who believed that would pick
/// the wrong one for the wrong reason.
String agentChatSurfaceDetail(AgentChatSurface surface) => switch (surface) {
  AgentChatSurface.list =>
    'One bubble per turn with the steps listed under it, like Hermes. It asks '
        'here, on a card, before it runs a command or changes a file.',
  AgentChatSurface.terminal =>
    "The assistant's own command-line app, live. It asks in its own words and "
        'you answer with the keyboard; typing mid-answer reaches the turn that '
        'is running.',
};
