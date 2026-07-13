import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/backend_detector.dart';
import '../logic/ollama_launch_controller.dart';
import '../logic/provider_run_controller.dart';
import 'api_engine_block.dart';
import 'engine_block.dart';
import 'external_server_block.dart';
import 'provider_running_card.dart';

/// Provider lifecycle. Enables the provider role when missing, then serves a
/// model — from a local GGUF (the main flow) or an external OpenAI-compatible
/// endpoint (`--at`) — and monitors the running provider. Downloading and
/// managing local models lives inline in the local engine block.
class ProviderView extends ConsumerStatefulWidget {
  const ProviderView({super.key});

  @override
  ConsumerState<ProviderView> createState() => _ProviderViewState();
}

class _ProviderViewState extends ConsumerState<ProviderView> {
  @override
  Widget build(BuildContext context) {
    final network = ref.watch(selectedNetworkProvider);

    // Reflect an engine that's still serving this grid (e.g. one that outlived
    // an app restart). Runs after the frame so it never mutates state mid-build;
    // the controller dedupes per grid.
    if (network != null) {
      final notifier = ref.read(providerRunControllerProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.reconcile(network.networkId);
      });
    }

    return const SectionScaffold(
      title: 'Model Engines',
      // _ServeSection owns its own scrolling: the running engine fills the
      // height (only its log scrolls), other states scroll as a page.
      child: _ServeSection(),
    );
  }
}

/// Gates on network/provider/run-state, then offers the local-model serve (the
/// main flow) with the BYO external `--at` form as a secondary option.
class _ServeSection extends ConsumerWidget {
  const _ServeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final network = ref.watch(selectedNetworkProvider);
    final run = ref.watch(providerRunControllerProvider);

    if (network == null) {
      return const Text('Select a grid first from the Grids tab.');
    }

    // Engine running on THIS grid: hand the card the full section height so the
    // header/banner pin and only the log scrolls (fixes the double scrollbar).
    if (run is ProviderRunActive && run.grid == network.networkId) {
      return ProviderRunningCard(starting: run.starting, log: run.log);
    }

    // Every other state scrolls as a page.
    return ListView(children: _bodyChildren(context, theme, network, run));
  }

  /// The scrollable body for the non-running states — enable-provider gate,
  /// "engine busy on another grid", or the serve forms (built-in + BYO).
  List<Widget> _bodyChildren(
    BuildContext context,
    ThemeData theme,
    NetworkCredential network,
    ProviderRunState run,
  ) {
    if (!network.isProvider) {
      // Sharing on THIS grid is locked (an admin hasn't turned engines on; a
      // consumer isn't allowed to), but installing the engine on this computer
      // needs no permission from any grid — so still offer the set-up. That way
      // a consumer can learn the app and get ready instead of hitting a wall,
      // and an admin can install while turning sharing on.
      return [
        const SizedBox(height: 16),
        EnableProviderCard(network: network),
        const SizedBox(height: 16),
        const NodeSetupCard(),
        const SizedBox(height: 16),
      ];
    }
    // One engine at a time: if one is already serving another grid, say so and
    // let the user stop it here first — don't show a Start form that would
    // silently leave the running engine to start a new one.
    if (run is ProviderRunActive && run.grid != network.networkId) {
      return [_EngineBusyElsewhere(runningGridId: run.grid)];
    }

    final failedNote = run is ProviderRunFailed
        ? Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("Couldn't start last time: ${run.message}",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          )
        : null;

    // Windows can't host the built-in (llama.cpp) engine yet — don't show the
    // node-setup/serve path there; it would only dead-end. Offer BYO instead.
    if (Platform.isWindows) {
      return [
        ?failedNote,
        const _BuiltInUnavailableNote(),
        const SizedBox(height: 16),
        // A hosted API provider needs no local engine, so it's the natural path
        // on Windows where the built-in one isn't available yet.
        ApiEngineBlock(network: network),
        const SizedBox(height: 16),
        _ExternalServers(network: network),
      ];
    }

    return [
      ?failedNote,
      EngineBlock(
        icon: Icons.dns_outlined,
        title: 'Local Engine',
        subtitle: 'Run a downloaded model on this computer with Llama.cpp.',
        child: ServeLocalCard(network: network),
      ),
      const SizedBox(height: 16),
      ApiEngineBlock(network: network),
      const SizedBox(height: 16),
      _ExternalServers(network: network),
      const SizedBox(height: 16),
      const NodeSetupCard(),
      const SizedBox(height: 16),
    ];
  }
}

/// Shown on Windows in place of the built-in engine path, which isn't supported
/// there yet — so the user understands why and where to go instead.
class _BuiltInUnavailableNote extends StatelessWidget {
  const _BuiltInUnavailableNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Built-in engine not available on Windows yet',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    "Running a model directly on this Windows computer isn't "
                    'supported yet. You can still connect your own AI server below, '
                    'or use models other people share on the grid from the Playground.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when an engine is already serving a *different* grid. Only one engine
/// runs at a time, so rather than a Start form that would silently stop it, this
/// names the busy grid and offers a single Stop so the user is in control.
class _EngineBusyElsewhere extends ConsumerWidget {
  const _EngineBusyElsewhere({required this.runningGridId});

  final String runningGridId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final runningName =
        ref.watch(sessionProvider).byName(runningGridId)?.name ?? 'another grid';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.dns, color: AppPalette.online, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('An engine is already running on $runningName',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'You can run an engine on only one grid at a time. Stop '
                        'it to start one on this grid.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () =>
                    ref.read(providerRunControllerProvider.notifier).stop(),
                icon: const Icon(Icons.stop),
                label: Text('Stop engine on $runningName'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "bring your own engine" section. Each external framework detected on this
/// machine (Ollama, LM Studio, …) gets its own card, pre-filled and ready to
/// start in one tap; a collapsed "Connect your own engine" expander follows for
/// any other OpenAI-compatible engine you run on this computer.
class _ExternalServers extends ConsumerWidget {
  const _ExternalServers({required this.network});

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
        if (isScanning) const _ScanningForServersNote(),
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
                key: ValueKey(backend.kind), backend: backend),
          const SizedBox(height: 16),
        ],
        ExternalServerBlock(
          key: const ValueKey('manual'),
          network: network,
          collapsible: true,
          icon: Icons.computer_outlined,
          title: 'Connect your own engine',
          subtitle:
              'Advanced — point Grid at an OpenAI-compatible engine you run on '
              'this computer.',
        ),
      ],
    );
  }
}

/// e.g. `localhost:11434/v1 · 3 models`.
String _backendSubtitle(DetectedBackend backend) {
  final host = backend.baseUrl.replaceFirst(RegExp(r'^https?://'), '');
  final count = backend.models.length;
  final models =
      count == 0 ? 'no models reported' : '$count model${count == 1 ? '' : 's'}';
  return '$host · $models';
}

/// A quiet "still looking" line shown while we probe this computer for running
/// AI engines (Ollama, LM Studio, …), so the not-yet-populated list doesn't read
/// as "nothing found" in the first second or two.
class _ScanningForServersNote extends StatelessWidget {
  const _ScanningForServersNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Looking for AI engines on this computer…',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
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
            Text(launch.message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: starting
                  ? null
                  : () =>
                      ref.read(ollamaLaunchControllerProvider.notifier).start(),
              icon: starting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(
                  starting ? 'Starting ${backend.label}…' : 'Run ${backend.label}'),
            ),
          ),
        ],
      ),
    );
  }
}
