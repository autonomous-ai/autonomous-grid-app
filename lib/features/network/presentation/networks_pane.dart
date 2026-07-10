import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import 'getting_started_coach.dart';
import 'network_detail.dart';
import 'network_list.dart';

/// The Networks section: a list column on the left, the selected network's
/// detail on the right (Tailscale Devices ▸ device-detail). A first-run coach
/// sits across the top for consumer-only accounts (see [GettingStartedCoach]).
class NetworksPane extends ConsumerWidget {
  const NetworksPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedNetworkProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GettingStartedCoach(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NetworkList(),
              const VerticalDivider(width: 1),
              Expanded(
                child: selected == null
                    ? const _NoSelection()
                    : NetworkDetail(network: selected),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 40, color: AppPalette.textFaint),
          SizedBox(height: 12),
          Text('Select a grid to see its details.',
              style: TextStyle(color: AppPalette.textSecondary)),
        ],
      ),
    );
  }
}
