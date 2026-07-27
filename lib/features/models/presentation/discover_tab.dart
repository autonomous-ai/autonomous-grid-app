import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/empty_state.dart';
import '../logic/model_manager_filter.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import 'download_row.dart';
import 'suggested_models_section.dart';

/// What to get next: the catalog's device-ranked picks, and — when the search
/// box holds a `owner/repo:file.gguf` spec rather than a search word — the way to
/// download something the catalog doesn't list.
///
/// That paste box used to be a Material [ExpansionTile] folded under the list: a
/// download the user had to expand a tile to reach, and progress they had to
/// expand a tile to watch. Both now live in the list itself.
class DiscoverTab extends ConsumerWidget {
  const DiscoverTab({
    super.key,
    required this.fallback,
    required this.fallbackLoading,
    required this.catalogReadable,
    required this.query,
  });

  /// The offline `grid catalog` suggestions, shown when the API can't be
  /// reached. Already filtered to what *isn't* downloaded.
  final List<ShelfModel> fallback;

  /// Whether that offline list is still loading, so a transient API failure
  /// doesn't flash an empty fallback before it arrives.
  final bool fallbackLoading;

  /// Whether `grid catalog` answered at all.
  ///
  /// Separate from `fallback.isEmpty` on purpose: the two coincide only when the
  /// CLI genuinely failed. A working catalog whose every model is already on
  /// disk also yields an empty [fallback], and calling that "couldn't reach the
  /// catalog" is a lie the user can't act on.
  final bool catalogReadable;

  final TextEditingController query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: query,
      builder: (context, _) {
        final pull = ref.watch(modelPullControllerProvider);
        final spec = query.text.trim();
        final pasted = looksLikePullSpec(spec);

        return ListView(
          // See InstalledTab: a greedy list defeats the Column's
          // `mainAxisSize.min` and the dialog stands at its ceiling however
          // little is in it.
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          children: [
            // A pasted spec answers the question the tab asks, so it goes first
            // and the ranked list below it becomes context rather than an
            // obstacle between the paste and the button that acts on it.
            if (pasted) ...[
              PasteSpecRow(spec: spec),
              const SizedBox(height: 8),
            ],
            if (pull is ModelPulling) ...[
              DownloadRow(state: pull),
              const SizedBox(height: 8),
            ],
            if (pull is ModelPullDone) ...[
              PullResultRow(
                message: '${pull.file} — close this dialog to start it.',
                onDismiss: () =>
                    ref.read(modelPullControllerProvider.notifier).reset(),
              ),
              const SizedBox(height: 8),
            ],
            if (pull is ModelPullFailed) ...[
              PullResultRow(
                message: pull.message,
                failed: true,
                onDismiss: () =>
                    ref.read(modelPullControllerProvider.notifier).reset(),
              ),
              const SizedBox(height: 8),
            ],
            // A spec in the box would filter every catalog row away, leaving a
            // "no match" state under the very row that says what to do. The
            // ranked list simply stays unfiltered while a spec is pasted.
            SuggestedForDevice(
              fallback: fallback,
              fallbackLoading: fallbackLoading,
              catalogReadable: catalogReadable,
              filter: pasted ? '' : spec,
            ),
          ],
        );
      },
    );
  }
}

/// The row a pasted `owner/repo:file.gguf` turns into: what it will download,
/// and the button that starts it.
///
/// Raised on [AppCard.tint18] rather than the ordinary row fill — it isn't one
/// of the catalog's suggestions, it's the thing the user just asked for, and it
/// has to read as the answer to what they typed.
///
/// Measured against the dialog (`menuFill`, `#1E1E1E` dark / white light):
/// `tint18` composites to `#21283E` / `#EFF2FD`, giving **1.141 : 1** dark and
/// **1.118 : 1** light — both a step clear of the ordinary row's
/// `bubbleFill` (1.074 / 1.111), and lifted further by [AppGlass.cardShadow].
class PasteSpecRow extends ConsumerWidget {
  const PasteSpecRow({super.key, required this.spec});

  final String spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final lines = parsePullSpecs(spec);
    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppCard.tint25,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.link_rounded,
                size: 16,
                // accentOnSurface, not accentStrong: on this washed row
                // accentStrong measures 4.02:1 in dark, under the 4.5 a glyph
                // carrying meaning needs. accentOnSurface reaches 4.73.
                color: AppPalette.accentOnSurface,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lines.length == 1
                        ? 'Download this model'
                        : 'Download ${lines.length} parts',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: AppFont.medium,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lines.first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.28,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: pulling
                  ? null
                  : () => ref
                        .read(modelPullControllerProvider.notifier)
                        .pull(spec),
              icon: const Icon(
                Icons.download_outlined,
                size: AppControl.iconSize,
              ),
              label: const Text('Download'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppControl.heightSmall),
                padding: AppControl.paddingSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The outcome of a finished download — landed, or failed — as a row in the
/// list, with a way to dismiss it.
///
/// The old dialog printed both inside the collapsed paste card, where a failure
/// was invisible unless the tile happened to be open.
class PullResultRow extends StatelessWidget {
  const PullResultRow({
    super.key,
    required this.message,
    required this.onDismiss,
    this.failed = false,
  });

  final String message;
  final VoidCallback onDismiss;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final tone = failed ? theme.colorScheme.error : AppPalette.online;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 10, 12),
        child: Row(
          children: [
            Icon(
              failed ? Icons.error_outline : Icons.check_circle,
              size: 18,
              color: tone,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.32,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            AppIconButton(
              icon: Icons.close,
              tooltip: 'Dismiss',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-line status row (loading / no-match / offline) in the Discover list.
///
/// Built as a proper tile rather than the centred `Row` of loose text the old
/// section used: an offline catalog left one sentence floating in the middle of
/// a dialog whose every other element had a shape, and — worse — offered nothing
/// to press, so the only way to retry was to close the dialog and reopen it.
class DiscoverStatusRow extends StatelessWidget {
  const DiscoverStatusRow({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  /// Null shows a spinner — the loading case.
  final IconData? icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppPalette.cardBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: icon == null
                  ? const AppSpinner()
                  : Icon(icon, size: 16, color: AppPalette.textSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: AppFont.medium,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.28,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: 12),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppControl.heightSmall),
                  padding: AppControl.paddingSmall,
                ),
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Nothing in the catalog matched what was typed. Reuses the shared empty state
/// so it reads like every other "no match" in the app.
class DiscoverNoMatch extends StatelessWidget {
  const DiscoverNoMatch({super.key, required this.needle});

  final String needle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: EmptyState.noMatches(
        message:
            'No suggested model matches "$needle". You can paste a '
            'owner/repo:file.gguf above instead.',
      ),
    );
  }
}
