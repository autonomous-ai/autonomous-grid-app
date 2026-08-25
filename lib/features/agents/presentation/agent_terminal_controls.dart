import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/composer_buttons.dart';

/// The controls under a chat that *is* an agent's CLI — everything the terminal
/// itself cannot decide, and nothing it can.
///
/// The composer is gone here: the CLI takes its own input, so a second box above
/// it would be a second place to type one sentence, and the two would disagree
/// about what "Send" meant the moment a turn was running. What is left is the
/// three choices the app makes *for* the CLI rather than inside it — which agent
/// to run, which grid model to run it on, and what it may do to this computer —
/// because each reaches the program as a flag before it starts and none of them
/// can be reached from the keyboard once it has.
///
/// They describe the **next** session, not the one on screen: the argv is built
/// once, when the CLI starts. So Restart sits in the same row, and the line under
/// it says so — a picker whose effect the user cannot see or trigger is a control
/// that lies (§5).
class AgentTerminalControls extends StatelessWidget {
  const AgentTerminalControls({
    super.key,
    required this.approvalPicker,
    required this.agentPicker,
    required this.modelPicker,
    required this.onRestart,
  });

  /// What the agent may do to this computer, as the flags its CLI starts with.
  final Widget? approvalPicker;

  /// Which of the interactive CLIs this chat runs. It has no equivalent inside
  /// any of them — the terminal can change what an agent does, never which agent
  /// it is.
  final Widget? agentPicker;

  /// The grid model the CLI is started on. Claude Code's own `/model` is not this
  /// control: it changes the model *it* knows about, while the name here is what
  /// reaches the grid as `--model`.
  final Widget modelPicker;

  /// Throws the running CLI away and starts it on what these controls now say.
  final VoidCallback onRestart;

  /// The narrowest each group draws at, and the flex weights that share the row
  /// in that proportion — the same rule the composer's action row follows, so
  /// both bars tighten instead of striping on a narrow pane.
  ///
  /// Left: the access pill's own floor, 58. Right: agent 58 + gap 8 + model 58 +
  /// gap 4 + restart 32.
  static const _leftFloor = 58;
  static const _rightFloor = 160;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (approvalPicker != null)
              Flexible(
                flex: _leftFloor,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 178),
                  child: approvalPicker,
                ),
              ),
            const SizedBox(width: 8),
            Flexible(
              flex: _rightFloor,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (agentPicker != null) ...[
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 132),
                        child: agentPicker,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Fixed at the composer's 140 for the same reason: a pill that
                  // resized to each model's name would make the row twitch on
                  // every switch.
                  Flexible(child: SizedBox(width: 140, child: modelPicker)),
                  const SizedBox(width: 4),
                  ComposerIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Start the agent again on these settings',
                    onPressed: onRestart,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'The agent starts with these. Restart to use a change — it begins a '
          'new conversation.',
          style: TextStyle(fontSize: 11.5, color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}
