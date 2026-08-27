import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import 'getting_started_coach.dart';
import 'network_detail.dart';
import 'network_list.dart';

/// The Grids screen, inside Settings: a list column on the left, the selected
/// grid's detail on the right (Tailscale Devices ▸ device-detail). A first-run
/// coach sits across the top for consumer-only accounts
/// (see [GettingStartedCoach]).
///
/// The way back out is Settings' own header — this pane doesn't own the window.
class NetworksPane extends ConsumerWidget {
  const NetworksPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GettingStartedCoach(),
        Expanded(
          child: _NetworksContent(selected: ref.watch(selectedNetworkProvider)),
        ),
      ],
    );
  }
}

class _NetworksContent extends StatelessWidget {
  const _NetworksContent({required this.selected});

  final NetworkCredential? selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The rail is navigation — the grid names on it are how you move around,
        // not what the page is showing you. Same rule as the shell's own sidebar
        // (`home_shell.dart`) and every button's label ([unselectableLabel]).
        const SelectionContainer.disabled(child: NetworkList()),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? const _NoSelection()
              : NetworkDetail(network: selected!),
        ),
      ],
    );
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 40, color: AppPalette.textFaint),
          SizedBox(height: 12),
          Text(
            'Select a grid to see its details.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}
