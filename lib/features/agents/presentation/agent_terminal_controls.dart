import 'package:flutter/material.dart';

import '../../../shared/widgets/composer_buttons.dart';

/// The controls under a chat that *is* an agent's CLI — the one choice the
/// terminal cannot make for itself, and nothing else.
///
/// There is no composer here: the CLI takes its own input, so a second box above
/// it would be a second place to type one sentence. There is no model or access
/// picker either, for the same reason pointing the other way — a running CLI
/// owns both (Claude Code cycles access on shift+tab and picks a model on
/// `/model`), and an app-side copy of a control the program is already showing
/// would go stale the moment the user used the real one.
///
/// Which agent runs is the exception, and the only one: no keystroke inside
/// Claude Code can turn it into Codex. Picking a different one starts it in
/// place of what is running — see `AgentTerminalsController.ensure`.
class AgentTerminalControls extends StatelessWidget {
  const AgentTerminalControls({
    super.key,
    required this.agentPicker,
    required this.onRestart,
  });

  /// Which of the interactive CLIs this chat runs, or null while none is
  /// installed to choose between.
  final Widget? agentPicker;

  /// Starts the agent again from scratch — the way out of a wedged CLI, and how
  /// a session picks up what it was born without.
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (agentPicker != null) ...[
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 132),
            child: agentPicker,
          ),
        ),
        const SizedBox(width: 4),
      ],
      ComposerIconButton(
        icon: Icons.refresh_rounded,
        tooltip: 'Start the agent again — it begins a new conversation',
        onPressed: onRestart,
      ),
    ],
  );
}
