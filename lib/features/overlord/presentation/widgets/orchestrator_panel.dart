import 'package:flutter/material.dart';

import 'ghost_button.dart';
import 'panel_frame.dart';
import 'panel_message.dart';

/// Right column placeholder — the terminal/PTY session manager lands here next.
/// The header actions are shown for layout fidelity but are inert for now.
class OrchestratorPanel extends StatelessWidget {
  const OrchestratorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return PanelFrame(
      label: 'Overlord Orchestrator',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          GhostButton(icon: Icons.open_in_full, label: 'Fullscreen'),
          SizedBox(width: 8),
          GhostButton(icon: Icons.refresh, label: 'Restart'),
        ],
      ),
      child: const PanelMessage(
        icon: Icons.terminal_outlined,
        text: 'Orchestrator sessions\ncoming next',
      ),
    );
  }
}
