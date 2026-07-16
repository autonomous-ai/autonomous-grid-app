import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/node_setup/logic/background_model_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_spinner.dart';
import '../shell_state.dart';
import 'hosting_summary.dart';
import 'top_bar_pill.dart';

/// The slim strip above the open section: what's live on the active grid (how
/// many computers are hosting, how many models they serve) and any model the
/// user is downloading. Doubles as the window's drag handle on the right.
///
/// Deliberately quiet — the account, the grid switcher and the navigation all
/// live in the sidebar, so nothing competes with the conversation below.
class AppTopBar extends StatelessWidget {
  const AppTopBar({super.key});

  static const double height = 46;

  @override
  Widget build(BuildContext context) {
    return const DragToMoveArea(
      child: SizedBox(
        height: height,
        // Seamless with the content, like Codex — no fill, no border, no blur.
        // The pills simply float on the pane; the bar is just their row and the
        // window's drag handle. Each pill stays unmounted when it has nothing to
        // show, so an idle grid leaves the bar empty rather than showing a bare
        // capsule.
        child: Padding(
          padding: EdgeInsets.only(left: 16, right: 18),
          child: Row(
            children: [Spacer(), _ModelDownloadPill(), HostingSummary()],
          ),
        ),
      ),
    );
  }
}

/// The background model download, shown in the top bar so a user who went
/// straight into chat can see their own model arriving. Nothing when idle or
/// done; on a failure it becomes a tap-through to the Engines tab to retry.
class _ModelDownloadPill extends ConsumerWidget {
  const _ModelDownloadPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(backgroundModelControllerProvider)) {
      ModelDownloadRunning(:final progress) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TopBarPill(child: _DownloadingLabel(pct: progress?.pct)),
      ),
      ModelDownloadFailed() => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: 'Open Engines to try again',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.engines),
            child: const TopBarPill(child: _DownloadFailedLabel()),
          ),
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _DownloadingLabel extends StatelessWidget {
  const _DownloadingLabel({required this.pct});

  final double? pct;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final pct = this.pct;
    final label = pct == null
        ? 'Downloading model…'
        : 'Downloading model · ${pct.round()}%';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(size: SpinnerSize.small),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _DownloadFailedLabel extends StatelessWidget {
  const _DownloadFailedLabel();

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 14, color: error),
        const SizedBox(width: 6),
        Text(
          'Model download failed',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: error,
          ),
        ),
      ],
    );
  }
}
