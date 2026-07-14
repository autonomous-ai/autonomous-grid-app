import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import 'hosting_summary.dart';

/// The slim strip above the open section: which grid you're working in, and
/// what's live on it (how many computers are hosting, how many models they
/// serve). Doubles as the window's drag handle on the right of the window.
///
/// Deliberately quiet — the account and the navigation live in the sidebar, so
/// nothing competes with the conversation below.
class AppTopBar extends ConsumerWidget {
  const AppTopBar({super.key});

  static const double height = 46;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(selectedNetworkProvider);

    return DragToMoveArea(
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AppPalette.windowBg,
            border: Border(bottom: BorderSide(color: Color(0x0A000000))),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 18),
            child: Row(
              children: [
                const Spacer(),
                const _StatusPill(child: HostingSummary()),
                if (grid != null) ...[
                  const SizedBox(width: 8),
                  _StatusPill(child: _CurrentGridLabel(grid: grid)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: child,
      ),
    );
  }
}

/// The active grid — a live Running / Stopped dot, a faint "Grid ·" caption, then
/// the name. No box: it reads as a label, so you always know which grid answers
/// your messages without it competing with the window chrome.
class _CurrentGridLabel extends ConsumerWidget {
  const _CurrentGridLabel({required this.grid});

  final NetworkCredential grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref
        .watch(gridOverviewForProvider(grid.networkId))
        .asData
        ?.value
        .state;
    final running = state?.toLowerCase() == 'running';
    return ConstrainedBox(
      // Cap the width and ellipsize so a long grid name can't overflow the bar.
      constraints: const BoxConstraints(maxWidth: 280),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: running ? AppPalette.online : AppPalette.offline,
            size: 8,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Grid · ',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  TextSpan(
                    text: grid.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
