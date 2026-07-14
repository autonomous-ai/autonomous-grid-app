import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import 'getting_started_coach.dart';
import 'network_detail.dart';
import 'network_list.dart';

/// The Networks section: a list column on the left, the selected network's
/// detail on the right (Tailscale Devices ▸ device-detail). A first-run coach
/// sits across the top for consumer-only accounts (see [GettingStartedCoach]).
class NetworksPane extends ConsumerWidget {
  const NetworksPane({super.key, this.fullScreen = false});

  final bool fullScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedNetworkProvider);
    final content = _NetworksContent(selected: selected);

    if (!fullScreen) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const GettingStartedCoach(),
          Expanded(child: content),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FullScreenHeader(),
        const GettingStartedCoach(),
        Expanded(child: content),
      ],
    );
  }
}

class _FullScreenHeader extends ConsumerWidget {
  const _FullScreenHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final left = Platform.isMacOS ? 78.0 : 16.0;
    return DragToMoveArea(
      child: SizedBox(
        height: 54,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: AppPalette.windowBg),
          child: Padding(
            padding: EdgeInsets.fromLTRB(left, 10, 18, 8),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: AppGlass.cardShadow,
                  ),
                  child: TextButton.icon(
                    onPressed: () => ref
                        .read(shellSectionProvider.notifier)
                        .select(ShellSection.chat),
                    style: TextButton.styleFrom(
                      foregroundColor: AppPalette.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 34),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(Icons.arrow_back_rounded, size: 17),
                    label: const Text('Back to app'),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Grids',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
        const NetworkList(),
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
    return const Center(
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
