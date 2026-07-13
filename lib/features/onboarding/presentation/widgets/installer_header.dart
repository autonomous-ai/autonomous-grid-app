import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/installer_controller.dart';
import '../../logic/installer_rows.dart';

/// The installer's title, its "x of N steps" counter, and a progress bar.
///
/// The headline changes with the state rather than staying a static "Setting
/// up…": on a failure it must not keep implying work is happening, and when it
/// finishes it should say so.
class InstallerHeader extends ConsumerWidget {
  const InstallerHeader({
    super.key,
    required this.done,
    required this.total,
    required this.state,
  });

  final int done;
  final int total;
  final InstallerState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final download = ref.watch(installerDownloadProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_headline, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                _subtitle(download?.pct),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              '$done of $total steps',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : done / total,
            minHeight: 4,
          ),
        ),
      ],
    );
  }

  String get _headline => switch (state) {
    InstallerFailed() => "Setup didn't finish",
    InstallerDone() => 'Ready',
    _ => 'Setting up your AI',
  };

  /// One honest line about what is happening. While a model downloads, the
  /// percentage goes here — it's the one step long enough for a user to wonder
  /// whether anything is happening at all.
  String _subtitle(double? downloadPct) => switch (state) {
    InstallerFailed() =>
      'You can try again, or go in and use an engine someone else shares.',
    InstallerDone() => 'Your computer is ready and shared on your grid.',
    InstallerRunning() when downloadPct != null =>
      'Downloading the model — ${downloadPct.toStringAsFixed(0)}% done.',
    InstallerRunning() => 'This takes a few minutes. You can leave it running.',
    _ => 'Grid will set this computer up for you.',
  };
}
