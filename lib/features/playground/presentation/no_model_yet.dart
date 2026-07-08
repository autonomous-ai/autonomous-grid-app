import 'package:flutter/material.dart';

/// Blocked state when no model can answer yet. Points provider-capable users to
/// the Engines tab to start one; pure consumers are told to wait for a provider.
/// Shared by the Playground dialog and the Chat tab — the caller supplies
/// [onGoToEngines] (which may pop a dialog first, then navigate).
class NoModelYet extends StatelessWidget {
  const NoModelYet({
    super.key,
    required this.canManage,
    required this.onGoToEngines,
  });

  final bool canManage;
  final VoidCallback onGoToEngines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No model is running yet',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              canManage
                  ? 'Start an engine on this grid to chat with a model.'
                  : 'Wait for someone on this grid to bring a model online, or '
                      'ask the grid owner to run one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (canManage) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onGoToEngines,
                icon: const Icon(Icons.dns_outlined, size: 18),
                label: const Text('Go to Engines'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
