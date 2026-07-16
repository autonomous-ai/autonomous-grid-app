import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/log_view.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/provider_run_controller.dart';

/// Status + streamed log + Stop for a running provider. Fills the height it's
/// given so the header/banner pin and only the log scrolls (one scrollbar, not a
/// page scroll stacked on the log's). Once serving (not [starting]) it confirms
/// the model is live and links to the Playground to try it.
class ProviderRunningCard extends ConsumerWidget {
  const ProviderRunningCard({
    super.key,
    required this.starting,
    required this.log,
  });

  final bool starting;
  final List<String> log;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.hero,
      expand: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (starting)
                const AppSpinner()
              else
                Icon(Icons.dns, color: AppPalette.online, size: 18),
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
            _LiveBanner(
              theme: theme,
              onOpenPlayground: () => openPlaygroundDialog(context, ref),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(child: LogView(lines: log)),
        ],
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
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, color: AppPalette.online, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your model is live on the grid',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Others on the grid can use it now. Try it yourself in the Playground.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
