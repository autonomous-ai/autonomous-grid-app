import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/node_probe.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
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
/// [chosen] null falls to the agent's own default — the terminal. **Deliberately
/// not the setting**: a chat that recorded no surface is one that started
/// before the setting existed, and reading the live value there would take a
/// running terminal chat's conversation off screen the moment someone changed
/// their mind about the *next* chat. For a chat that is already under way, pass
/// [recordedChatSurface] rather than the raw record: the transcript settles
/// most of the chats that recorded nothing, and the default is only for the
/// ones it cannot.
/// [terminalAvailable] is the runtime half of the same question, and it is false
/// only for an agent whose interactive CLI this computer cannot actually run.
/// Hermes is the one that has such a condition: `hermes --tui` is a Node bundle
/// (≥20) while the rest of Hermes is Python, so a machine can answer every ACP
/// turn perfectly and still be unable to draw the TUI. Passed in rather than
/// probed here so this stays pure — see [hermesTuiReadyProvider], which is where
/// the probe lives.
///
/// Falling back to [AgentChatSurface.list] rather than refusing: an agent that
/// cannot draw its own program can still hold a conversation, and the chat the
/// user asked for is more important than the shape they asked for it in.
AgentChatSurface agentChatSurface(
  AgentTool tool, {
  AgentChatSurface? chosen,
  bool terminalAvailable = true,
}) {
  if (!tool.hasInteractiveCli || !terminalAvailable) {
    return AgentChatSurface.list;
  }
  return chosen ?? AgentChatSurface.terminal;
}

/// Whether this computer can run `hermes --tui` — a Node ≥20 the *app's own*
/// spawns can reach.
///
/// Probed once and cached by Riverpod, because the answer changes only when the
/// user installs Node, and a subprocess per rebuild would cost a chat screen a
/// process on every keystroke. `AsyncValue` rather than a bool so the unresolved
/// state is distinguishable from "no": treating "still probing" as a no would
/// flip a Hermes chat to the message surface for the first frames and then flip
/// it back, and a chat that changes shape underneath the user reads as a bug
/// whichever way it settles.
final hermesTuiReadyProvider = FutureProvider<bool>(
  (ref) => probeHermesTuiReady(),
);

/// [hermesTuiReadyProvider] as the yes/no the surface rule needs.
///
/// **Unresolved counts as available.** The probe takes a few milliseconds and
/// the alternative is the flicker described above; a Hermes chat that opens a
/// terminal on a machine with no Node gets Hermes's own error on screen, which
/// is a worse first frame than the truth but a better one than a pane that
/// swapped itself out after the user had started reading it.
bool _terminalAvailable(Ref ref, AgentTool tool) {
  if (tool != AgentTool.hermes) return true;
  return ref.watch(hermesTuiReadyProvider).asData?.value ?? true;
}

/// The surface a **new** chat with [tool] will start in — the one setting on
/// the Appearance screen, as far as this computer can honour it for [tool].
///
/// Still asked per agent, not because the setting is: whether the program can
/// be drawn here is (Hermes's needs a Node this Mac may not have), and a caller
/// that read the setting directly would start a chat in a surface this machine
/// cannot draw.
final agentChatSurfaceProvider = Provider.family<AgentChatSurface, AgentTool>((
  ref,
  tool,
) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatSurface));
  return agentChatSurface(
    tool,
    chosen: chosen,
    terminalAvailable: _terminalAvailable(ref, tool),
  );
});

/// The surface [chat] is known to be in — what it recorded, else what its
/// transcript proves.
///
/// A chat that recorded nothing started before the record existed (2026-08-26),
/// and its messages settle it: a terminal chat commits nothing to
/// `Conversation.messages`, so a transcript with anything in it is a message
/// list whatever its agent's default is today. Reading the default there was
/// the bug — every chat from before that day has a transcript, and the default
/// opened each one as an empty terminal with 188 messages nowhere on screen.
/// Only an empty transcript is left to the default, which is the one case the
/// default was written for: the terminal chats of the two days before the
/// record began.
AgentChatSurface? recordedChatSurface(Conversation chat) =>
    chat.surface ?? (chat.messages.isEmpty ? null : AgentChatSurface.list);

/// The surface the chat **on screen** is drawn in.
///
/// A chat draws the way it was drawn when it started: the surface is written
/// down at birth beside the agent (`Conversation.surface`), for the same reason
/// the agent is — from the first message the chat is a session, and the setting
/// belongs to the next chat rather than to this one.
final openChatSurfaceProvider = Provider<AgentChatSurface>((ref) {
  final tool = ref.watch(activeChatAgentProvider);
  final open = ref.watch(
    chatSessionsProvider.select((s) {
      final active = s.active;
      return (
        started: active != null,
        chosen: active == null ? null : recordedChatSurface(active),
      );
    }),
  );
  // Nothing open: what is in front of the user is a composer, and pressing Send
  // starts a chat the setting decides the shape of.
  if (!open.started) return ref.watch(agentChatSurfaceProvider(tool));
  return agentChatSurface(
    tool,
    chosen: open.chosen,
    terminalAvailable: _terminalAvailable(ref, tool),
  );
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
