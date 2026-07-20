import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../auto_router/presentation/auto_router_card.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/backend_detector.dart';
import '../logic/ollama_launch_controller.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'api_engine_block.dart';
import 'engine_block.dart';
import 'external_server_block.dart';
import 'serving_engines_section.dart';

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

/// Opens [url] in the user's default browser; best-effort (a failed open just
/// leaves the tappable fallback link in the running card as the way in). Mirrors
/// the login screen so a sign-in join opens the browser the same way.
Future<void> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The "This computer" body. A machine serves a *union* of engines on a grid
/// (ADR 0010), so this is a page, not a single running card: auto-routing at the
/// top (owner-only), then what's already serving (each engine stoppable on its
/// own), then the always-available ways to add another engine.
class _ServeSection extends ConsumerWidget {
  const _ServeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);

    // A sign-in join (codex OAuth) streams an authorize URL to approve — open it
    // the instant it arrives, exactly like the login screen opens the device URL.
    // The serving card also offers it as a tappable fallback if it didn't open.
    ref.listen(providerRunControllerProvider, (prev, next) {
      final was = prev is ProviderRunActive ? prev.signInUrl : null;
      final now = next is ProviderRunActive ? next.signInUrl : null;
      if (now != null && now != was) _openInBrowser(now);
    });

    if (network == null) {
      return const Text('Select a grid first from the Grids tab.');
    }
    return ListView(children: _children(context, ref, network));
  }

  List<Widget> _children(
    BuildContext context,
    WidgetRef ref,
    NetworkCredential network,
  ) {
    final run = ref.watch(providerRunControllerProvider);
    final serving = ref.watch(servingEnginesProvider);
    final children = <Widget>[const SizedBox(height: 16)];

    // Auto-routing (the reserved `auto` model) — owner-only, above the engines.
    if (network.isOwner) {
      children.addAll(const [AutoRouterCard(), SizedBox(height: 16)]);
    }

    // Sharing on THIS grid is locked (an admin hasn't turned engines on; a
    // consumer isn't allowed to). Installing the engine still needs no grid
    // permission, so offer the set-up instead of a wall — then stop here, since
    // a join would be rejected until sharing is on.
    if (!network.isProvider) {
      children.addAll([
        EnableProviderCard(network: network),
        const SizedBox(height: 16),
        const NodeSetupCard(),
        const SizedBox(height: 16),
      ]);
      return children;
    }

    // An engine on ANOTHER grid: remote has one identity per grid, so starting
    // one here leaves that one — warn before the add forms.
    if (run is ProviderRunActive && run.grid != network.networkId) {
      children.addAll([
        _EngineBusyElsewhere(runningGridId: run.grid),
        const SizedBox(height: 16),
      ]);
    }

    // What's already serving on THIS grid (the union), plus a transient row while
    // a newly-joined engine is still starting.
    final startingHere =
        run is ProviderRunActive &&
        run.grid == network.networkId &&
        run.starting;
    if (serving.isNotEmpty || startingHere) {
      children.addAll([
        ServingEnginesSection(network: network),
        const SizedBox(height: 16),
      ]);
    }

    if (run is ProviderRunFailed) {
      children.addAll([
        _FailedNote(message: run.message),
        const SizedBox(height: 8),
      ]);
    }

    children.addAll(_addEngineBlocks(network));
    children.add(const SizedBox(height: 16));
    return children;
  }

  /// The ways to add an engine — always available so a join stacks additively
  /// onto the machine's union (ADR 0010) instead of replacing what's running.
  List<Widget> _addEngineBlocks(NetworkCredential network) {
    if (Platform.isWindows) {
      // Windows can't host the built-in (llama.cpp) engine yet — offer BYO/API.
      return [
        const _AddEngineHeading(),
        const SizedBox(height: 8),
        const _BuiltInUnavailableNote(),
        const SizedBox(height: 16),
        ApiEngineBlock(network: network),
        const SizedBox(height: 16),
        _ExternalServers(network: network),
      ];
    }
    return [
      const _AddEngineHeading(),
      const SizedBox(height: 8),
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
    ];
  }
}

/// A quiet section label above the add-engine blocks, so the page reads as
/// "what's running" then "add another".
class _AddEngineHeading extends StatelessWidget {
  const _AddEngineHeading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        'Add an engine',
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The last start's failure, surfaced above the add forms so the user sees why
/// it didn't take before trying again.
class _FailedNote extends StatelessWidget {
  const _FailedNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      "Couldn't start last time: $message",
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
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
                  Text(
                    'Built-in engine not available on Windows yet',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Running a model directly on this Windows computer isn't "
                    'supported yet. You can still connect your own AI server below, '
                    'or use models other people share on the grid from the Playground.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
        ref.watch(sessionProvider).byName(runningGridId)?.name ??
        'another grid';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.dns, color: AppPalette.online, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'An engine is already running on $runningName',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'You can run an engine on only one grid at a time. Stop '
                        'it to start one on this grid.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
  final models = count == 0
      ? 'no models reported'
      : '$count model${count == 1 ? '' : 's'}';
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
          const AppSpinner(),
          const SizedBox(width: 10),
          Text(
            'Looking for AI engines on this computer…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
