import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/log_view.dart';
import '../logic/provider_run_controller.dart';

/// Status + streamed log + Stop for a running provider. Bounded height so it
/// embeds inside scrolling screens. Once serving (not [starting]) it confirms
/// the model is live and links to the Playground to try it.
class ProviderRunningCard extends ConsumerWidget {
  const ProviderRunningCard({
    super.key,
    required this.starting,
    required this.log,
    this.logHeight = 320,
  });

  final bool starting;
  final List<String> log;
  final double logHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (starting)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  const Icon(Icons.dns, color: Colors.green, size: 18),
                const SizedBox(width: 10),
                Text(starting ? 'Starting…' : 'Engine running'),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(providerRunControllerProvider.notifier).stop(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),
            if (!starting) ...[
              const SizedBox(height: 12),
              _LiveBanner(theme: theme, onOpenPlayground: () {
                ref.read(navSectionProvider.notifier).select(NavSection.playground);
              }),
            ],
            const SizedBox(height: 12),
            SizedBox(height: logHeight, child: LogView(lines: log)),
          ],
        ),
      ),
    );
  }
}

/// Plain-language "you're live" confirmation shown once the engine is serving —
/// so a first-timer knows it worked and where to try the model.
class _LiveBanner extends StatelessWidget {
  const _LiveBanner({required this.theme, required this.onOpenPlayground});

  final ThemeData theme;
  final VoidCallback onOpenPlayground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your model is live on the grid',
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  'Others on the grid can use it now. Try it yourself in the Playground.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onOpenPlayground,
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('Try it in Playground'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
