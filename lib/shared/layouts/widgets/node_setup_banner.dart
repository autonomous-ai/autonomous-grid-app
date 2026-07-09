import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/node_setup/logic/node_setup_controller.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../shell_state.dart';

/// App-wide strip that surfaces the background node-setup run so the user always
/// knows what's installing/downloading, from any tab. Shows a thin progress bar
/// while running, a calm neutral notice when the computer just can't auto-host
/// yet, and a red error row on a genuine failure; invisible otherwise.
class NodeSetupBanner extends ConsumerWidget {
  const NodeSetupBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(nodeSetupControllerProvider);
    return switch (setup) {
      NodeSetupRunning() => _RunningBanner(state: setup),
      NodeSetupFailed() => _FailedBanner(state: setup),
      _ => const SizedBox.shrink(),
    };
  }
}

class _RunningBanner extends StatelessWidget {
  const _RunningBanner({required this.state});
  final NodeSetupRunning state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = state.progress;
    final value = progress == null || progress.isIndeterminate
        ? null
        : progress.pct! / 100;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Setting up this computer · Step ${state.index + 1}/'
                    '${state.steps.length}: ${state.current.title}'
                    '${_suffix(progress)}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          LinearProgressIndicator(value: value, minHeight: 2),
        ],
      ),
    );
  }

  String _suffix(DownloadProgress? progress) {
    if (progress == null || progress.totalMb == null) return '';
    final pct =
        progress.pct == null ? '' : ' (${progress.pct!.toStringAsFixed(0)}%)';
    return ' · ${progress.doneMb.toStringAsFixed(0)}/'
        '${progress.totalMb!.toStringAsFixed(0)} MB$pct';
  }
}

class _FailedBanner extends ConsumerWidget {
  const _FailedBanner({required this.state});
  final NodeSetupFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final gentle = state.kind == NodeSetupFailureKind.unsupported;

    // A missing prerequisite isn't a crash — dress it as a calm neutral strip
    // (same family as the running banner) so a first-time user doesn't read
    // "the app is already broken" the moment it opens.
    final background = gentle
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.errorContainer;
    final foreground = gentle
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onErrorContainer;

    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(gentle ? Icons.info_outline : Icons.error_outline,
                size: 16, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                gentle
                    ? "This computer can't host its own engine — you can still "
                        'use engines shared on your grid.'
                    : 'Node setup stopped at "${state.step.title}". '
                        'Open Engines to retry.',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
            TextButton(
              onPressed: () => ref
                  .read(navSectionProvider.notifier)
                  .select(NavSection.provider),
              child: const Text('View'),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(nodeSetupControllerProvider.notifier).reset(),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}
