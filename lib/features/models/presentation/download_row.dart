import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../logic/model_pull_controller.dart';

/// A download in flight, as a row in the Discover list.
///
/// It used to be the body of a collapsed [ExpansionTile] at the bottom of the
/// dialog, which the tile had to auto-expand for so the progress bar and its
/// Cancel weren't hidden behind a fold. A download is the most important thing
/// on screen while it runs; it belongs in the list, at the top, where nothing
/// can fold it away.
class DownloadRow extends ConsumerWidget {
  const DownloadRow({super.key, required this.state});

  final ModelPulling state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final progress = state.progress;
    final fraction = (progress != null && !progress.isIndeterminate)
        ? progress.pct! / 100
        : null;

    final heading = state.total > 1
        ? 'Downloading part ${state.current} of ${state.total}'
        : 'Downloading a model';

    final detail = switch (progress) {
      null => 'Starting…',
      _ when progress.isIndeterminate =>
        '${progress.doneMb.toStringAsFixed(1)} MB',
      _ =>
        '${progress.doneMb.toStringAsFixed(1)} / '
            '${progress.totalMb!.toStringAsFixed(1)} MB · '
            '${progress.pct!.toStringAsFixed(0)}%',
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppCard.tint18,
                borderRadius: BorderRadius.circular(10),
              ),
              // The app's one "still alive" beat (§6) — a static download glyph
              // beside a bar that hasn't moved yet reads as a stall.
              child: const AppSpinner(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    heading,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: AppFont.medium,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    state.spec,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.28,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AppProgressBar(value: fraction),
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.2,
                      // Tabular figures: without them the percentage jitters
                      // sideways on every tick as digit widths change.
                      fontFeatures: AppFont.tabularFigures,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () =>
                  ref.read(modelPullControllerProvider.notifier).cancel(),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppControl.heightSmall),
                padding: AppControl.paddingSmall,
                // The error colour marks it as the destructive way out of a
                // running download.
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
