import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/node_setup/logic/node_setup_controller.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../shell_state.dart';

/// App-wide strip that surfaces the background node-setup run so the user always
/// knows what's installing/downloading, from any tab. Shows a thin progress bar
/// while running and a slim error row on failure; invisible otherwise.
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

class _RunningBanner extends ConsumerWidget {
  const _RunningBanner({required this.state});
  final NodeSetupRunning state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
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
                TextButton(
                  onPressed: () => ref
                      .read(navSectionProvider.notifier)
                      .select(NavSection.models),
                  child: const Text('View'),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(nodeSetupControllerProvider.notifier).cancel(),
                  child: const Text('Cancel'),
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
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 16, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Node setup stopped at "${state.step.title}". Open Models to retry.',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => ref
                  .read(navSectionProvider.notifier)
                  .select(NavSection.models),
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
