import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/log_view.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'serving_engine_tile.dart';

/// What this machine is serving on the active grid: one row per engine in its
/// union (ADR 0010), each stoppable on its own, plus a transient "starting" row
/// while a new engine joins. One place to try the models and read the engine
/// log. Only shown when something is serving or starting — see `ProviderView`.
class ServingEnginesSection extends ConsumerWidget {
  const ServingEnginesSection({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = ref.watch(servingEnginesProvider);
    final run = ref.watch(providerRunControllerProvider);
    final active = run is ProviderRunActive && run.grid == network.networkId
        ? run
        : null;
    final starting = active?.starting ?? false;
    final signInUrl = active?.signInUrl;
    final log = active?.log ?? const <String>[];

    // Any non-responses model in the union can be tried in-app; a codex seat
    // can't (the Playground speaks chat/completions), so the hint drops then.
    final unionModels = [
      for (final engine in engines) ...engine.models,
    ].join(',');
    final canPlayground =
        engines.isNotEmpty && !isResponsesOnlyModel(unionModels);

    return GlassCard(
      style: GlassCardStyle.hero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            gridName: network.name,
            count: engines.length,
            onStopAll: engines.isEmpty
                ? null
                : () => ref.read(providerRunControllerProvider.notifier).stop(),
          ),
          for (final engine in engines)
            ServingEngineTile(engine: engine, gridId: network.networkId),
          if (starting) ...[
            const SizedBox(height: 8),
            const _StartingRow(),
            if (signInUrl != null) ...[
              const SizedBox(height: 12),
              _SignInPrompt(url: signInUrl),
            ],
          ],
          if (canPlayground) ...[
            const SizedBox(height: 12),
            _PlaygroundHint(onOpen: () => openPlaygroundDialog(context, ref)),
          ],
          if (log.isNotEmpty) ...[
            const SizedBox(height: 12),
            _LogExpander(lines: log),
          ],
        ],
      ),
    );
  }
}

/// The section header: a live dot, the grid name, a count, and a Stop all.
class _Header extends StatelessWidget {
  const _Header({
    required this.gridName,
    required this.count,
    required this.onStopAll,
  });

  final String gridName;
  final int count;
  final VoidCallback? onStopAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.dns, color: AppPalette.online, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            count == 0
                ? 'Serving on $gridName'
                : 'Serving on $gridName · $count',
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (onStopAll != null)
          TextButton.icon(
            onPressed: onStopAll,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('Stop all'),
          ),
      ],
    );
  }
}

/// The row shown while a newly-joined engine is still starting up.
class _StartingRow extends StatelessWidget {
  const _StartingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const AppSpinner(),
        const SizedBox(width: 12),
        Text('Starting a new engine…', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// A compact nudge to try the running models in the Playground.
class _PlaygroundHint extends StatelessWidget {
  const _PlaygroundHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: AppPalette.online, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Others on the grid can use these now. Try them yourself in the '
              'Playground.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: const Text('Playground'),
          ),
        ],
      ),
    );
  }
}

/// The engine log, collapsed by default — real detail for when something looks
/// wrong, out of the way when it doesn't.
class _LogExpander extends StatelessWidget {
  const _LogExpander({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: Text('Activity log', style: theme.textTheme.bodyMedium),
        children: [SizedBox(height: 200, child: LogView(lines: lines))],
      ),
    );
  }
}

/// Shown while a sign-in join (codex OAuth) waits for browser approval. The app
/// already opened the browser; this confirms what to do and offers a fallback
/// link in case it didn't open.
class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.url});

  final String url;

  Future<void> _open() async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.open_in_browser,
            color: theme.colorScheme.primary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Approve the sign-in in your browser',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Once you approve, sharing starts automatically. Didn’t open?',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open sign-in page'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
