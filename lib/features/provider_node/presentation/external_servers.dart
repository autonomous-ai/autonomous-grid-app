import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../models/logic/advertise_name.dart';
import '../logic/backend_detector.dart';
import '../logic/ollama_launch_controller.dart';
import '../logic/provider_run_controller.dart';
import 'engine_block.dart';
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
        ExternalServerBlock(
          key: const ValueKey('manual'),
          network: network,
          collapsible: true,
          icon: Icons.computer_outlined,
          title: 'Connect something else',
          subtitle:
              'Point Grid at any OpenAI-compatible engine running on this '
              'computer.',
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
    final theme = Theme.of(context);
    final launch = ref.watch(ollamaLaunchControllerProvider);
    final starting = launch is OllamaLaunchStarting;
    return EngineBlock(
      icon: Icons.dns_outlined,
      title: backend.label,
      subtitle: 'Installed on this computer, but not running yet',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (launch is OllamaLaunchFailed) ...[
            Text(
              launch.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: starting
                  ? null
                  : () => ref
                        .read(ollamaLaunchControllerProvider.notifier)
                        .start(),
              icon: starting
                  ? const AppSpinner()
                  : const Icon(Icons.play_arrow),
              label: Text(
                starting
                    ? 'Starting ${backend.label}…'
                    : 'Run ${backend.label}',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
