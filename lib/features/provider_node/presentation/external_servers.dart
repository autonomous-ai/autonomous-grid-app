import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/share_page_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/backend_detector.dart';
import '../logic/ollama_launch_controller.dart';
import '../logic/provider_run_controller.dart';
import 'engine_notes.dart';
import 'external_server_block.dart';

/// The "bring your own engine" section. Each external framework detected on this
/// machine (Ollama, LM Studio, …) gets its own card, pre-filled and ready to
/// start in one tap; a collapsed "Connect your own engine" expander follows for
/// any other OpenAI-compatible engine you run on this computer.
class ExternalServers extends ConsumerWidget {
  const ExternalServers({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backendsAsync = ref.watch(backendsProvider);
    final detected =
        backendsAsync.asData?.value.where((b) => b.isExternal).toList() ??
        const <DetectedBackend>[];
    // No data yet means we're still probing the machine — show that we're
    // looking so the empty list doesn't read as "nothing here".
    final isScanning = backendsAsync.isLoading && !backendsAsync.hasValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isScanning) const ScanningForServersNote(),
        for (final backend in detected) ...[
          if (backend.running)
            ExternalServerBlock(
              // Keyed by kind so each framework keeps its own form state across
              // rescans (and the user's edits aren't swapped between cards).
              key: ValueKey(backend.kind),
              network: network,
              icon: Icons.dns_outlined,
              title: backend.label,
              subtitle: _backendSubtitle(backend),
              initialEndpoint: backend.baseUrl,
              initialModel: backend.models.isEmpty ? '' : backend.models.first,
              initialAdvertise: backend.models.isEmpty
                  ? backend.label
                  : deriveAdvertiseName(backend.models.first),
              suggestedModels: backend.models,
            )
          else
            // Installed but not serving — offer to start it instead of a serve
            // form that would fail. The list refreshes once it's up.
            _NotRunningBackendBlock(
              key: ValueKey(backend.kind),
              backend: backend,
            ),
          const SizedBox(height: 16),
        ],
        // A rule with its own words, because what follows is not another
        // detected engine — it is the fallback for an engine Grid could not
        // find. Without it the manual form reads as a fourth card in the list
        // and the reader looks for their server in it.
        if (detected.isNotEmpty) ...[
          const _OrDivider(),
          const SizedBox(height: 16),
        ],
        ExternalServerBlock(
          key: const ValueKey('manual'),
          network: network,
          // Open, and bare. It used to fold away behind a header, which was
          // right while this sat three disclosures deep on a page of stacked
          // rows. On a pane of its own the rule above already names it and the
          // first field says the rest — a title and a subtitle here made the
          // page say "another endpoint" three times in six inches.
          collapsible: false,
        ),
      ],
    );
  }
}

/// e.g. `localhost:11434/v1 · 3 models`.
String _backendSubtitle(DetectedBackend backend) {
  final host = backend.baseUrl.replaceFirst(RegExp(r'^https?://'), '');
  final count = backend.models.length;
  final models = count == 0
      ? 'no models reported'
      : '$count model${count == 1 ? '' : 's'}';
  return '$host · $models';
}

/// A detected backend that's installed but not serving (today: Ollama). Rather
/// than a serve form that would fail, it says so plainly and offers to start it
/// in place — on success the list refreshes and the normal serve card takes over.
class _NotRunningBackendBlock extends ConsumerWidget {
  const _NotRunningBackendBlock({super.key, required this.backend});

  final DetectedBackend backend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final launch = ref.watch(ollamaLaunchControllerProvider);
    final starting = launch is OllamaLaunchStarting;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: SharePalette.accent.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(ShareMetrics.plateRadius),
        border: Border.all(color: SharePalette.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.dns_outlined, size: 22, color: SharePalette.accent),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      backend.label,
                      style: ShareType.cardTitle.copyWith(fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Installed on this computer, not running yet.',
                      style: ShareType.buttonHelper,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: starting
                    ? null
                    : () => ref
                          .read(ollamaLaunchControllerProvider.notifier)
                          .start(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: AppFont.semibold,
                  ),
                ),
                icon: starting
                    ? const AppSpinner.onAccent()
                    : const Icon(Icons.play_arrow, size: 16),
                label: Text(starting ? 'Starting…' : 'Launch & share'),
              ),
            ],
          ),
          if (launch is OllamaLaunchFailed) ...[
            const SizedBox(height: 12),
            Text(
              launch.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The rule between what was found here and what has to be typed in.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Divider(height: 1, color: AppPalette.divider)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR POINT AT ANOTHER ENDPOINT',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: AppFont.semibold,
              letterSpacing: 1.05,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        Expanded(child: Divider(height: 1, color: AppPalette.divider)),
      ],
    );
  }
}
