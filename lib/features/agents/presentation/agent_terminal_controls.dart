import 'package:flutter/material.dart';

import '../../../shared/widgets/composer_buttons.dart';

/// The controls under a chat that *is* an agent's CLI — the one thing the
/// terminal cannot do for itself, and nothing else.
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
/// agent when it starts ([Conversation.agent]) and keeps it, so the pill here
/// had nothing left to change — the terminal's own header already names who is
/// running.
class AgentTerminalControls extends StatelessWidget {
  const AgentTerminalControls({super.key, required this.onRestart});

  /// Starts the agent again from scratch — the way out of a wedged CLI, and how
  /// a session picks up what it was born without.
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      ComposerIconButton(
        icon: Icons.refresh_rounded,
        tooltip: 'Start the agent again — it begins a new conversation',
        onPressed: onRestart,
      ),
    ],
  );
}
