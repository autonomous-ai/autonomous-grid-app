import 'package:flutter/material.dart';

/// The strip under a chat that *is* an agent's CLI — and it is empty.
///
/// There is no composer here: the CLI takes its own input, so a second box above
/// it would be a second place to type one sentence. There is no model or access
/// picker either, for the same reason pointing the other way — a running CLI
/// owns both (Claude Code cycles access on shift+tab and picks a model on
/// `/model`), and an app-side copy of a control the program is already showing
/// would go stale the moment the user used the real one.
///
/// **The agent picker used to be the exception, and is gone.** It offered to
/// start a different CLI in place of the one running, which is not a control
/// over this session but the end of it: the conversation lives inside the
/// program, and the replacement has never read a word of it. A chat fixes its
/// agent when it starts (`Conversation.agent`) and keeps it, so the pill here
/// had nothing left to change — the terminal's own banner already names who is
/// running.
///
/// Which left one restart button standing under a program that has its own way
/// out of every state it can get into, and a lone icon floating below a terminal
/// reads as a control the terminal owns. Hidden on 2026-08-25.
///
/// **Hidden, not unwired.** [onRestart] still reaches the chat that owns this
/// terminal — `AgentTerminals.reopen`, with its resume points, its handover and
/// its grid setup — so putting the button back is a `ComposerIconButton` in
/// [build] and nothing else. The widget stays for the same reason: it is where
/// anything a terminal chat needs *underneath* it belongs, and the chat view
/// already gives it the room.
class AgentTerminalControls extends StatelessWidget {
  const AgentTerminalControls({super.key, required this.onRestart});

  /// Starts the agent again from scratch — the way out of a wedged CLI, and how
  /// a session picks up what it was born without. Nothing on screen calls it
  /// while the button is hidden; everything behind it is intact.
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
