import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/network/logic/create_network_controller.dart';

/// App-wide strip for the starter grid the app provisions on its own, so the
/// user sees it happen instead of a grid simply appearing (or, on a failure,
/// never appearing). Same strip family as [NodeSetupBanner] — the two announce
/// the app's two background chores in one visual language.
///
/// Only the *automatic* create is announced: a create the user started from the
/// dialog already shows its own spinner, and a second announcement would just
/// double up. Invisible once the grid is ready.
class GridProvisionBanner extends ConsumerWidget {
  const GridProvisionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(createNetworkControllerProvider);
    return switch (state) {
      CreateNetworkSubmitting(auto: true) => const _CreatingBanner(),
      CreateNetworkFailed(auto: true, :final message) => _FailedBanner(
        message: message,
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _CreatingBanner extends StatelessWidget {
  const _CreatingBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Setting up your grid — your own private space for running '
                    'and using AI models.',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

/// The starter grid couldn't be created. The user asked for nothing, so this
/// must say what's missing and offer the retry — otherwise the app just sits
/// there with no grid and no reason why.
class _FailedBanner extends ConsumerWidget {
  const _FailedBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onErrorContainer;
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Couldn't set up your grid: $message",
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
            TextButton(
              onPressed: () => ref
                  .read(createNetworkControllerProvider.notifier)
                  .createFirstGridIfNeeded(),
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(createNetworkControllerProvider.notifier).reset(),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}
