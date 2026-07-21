import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';

import '../../../infrastructure/state/models/engine_run.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/logic/engine_setup_controller.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../network/presentation/sharing_locked_view.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/backend_detector.dart';
import '../logic/engine_slots.dart';
import '../logic/ollama_launch_controller.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'add_engine_picker.dart';
import 'api_engine_block.dart';
import 'contribution_summary.dart';
import 'engine_block.dart';
import 'engine_cost_chip.dart';
import 'engine_failure_card.dart';
import 'engine_notes.dart';
import 'grid_scope_bar.dart';
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
class _ServeSection extends ConsumerStatefulWidget {
  const _ServeSection();

  @override
  ConsumerState<_ServeSection> createState() => _ServeSectionState();
}

class _ServeSectionState extends ConsumerState<_ServeSection> {
  /// Which add-engine form is open. Cloud leads: a hosted model needs no
  /// download, so it's the fastest way onto a grid — the same reason the stacked
  /// layout put it first.
  AddEngineKind _adding = AddEngineKind.cloud;

  @override
  Widget build(BuildContext context) {
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
    return ListView(children: _children(context, network));
  }

  List<Widget> _children(BuildContext context, NetworkCredential network) {
    final run = ref.watch(providerRunControllerProvider);
    final serving = ref.watch(servingEnginesProvider);

    // Names the grid every sentence below is about. First, and in every state:
    // the Settings pane has no top bar, so without this the page says "this
    // grid" repeatedly while nothing on screen says which one.
    final children = <Widget>[
      GridScopeBar(network: network),
      const SizedBox(height: 16),
    ];

    // Sharing on THIS grid is locked (an admin hasn't turned engines on; a
    // consumer isn't allowed to). Installing the engine still needs no grid
    // permission, so offer the set-up instead of a wall — then stop here, since
    // a join would be rejected until sharing is on.
    //
    // An admin sees the one-tap fix ([EnableProviderCard] grants itself the
    // role); everyone else gets [SharingLockedView], which explains what they
    // *can* do here. The two gates read different axes on purpose — see the note
    // on `NetworkCredential.isProvider` vs `.role`.
    if (!network.isProvider) {
      if (network.role == NetworkRole.admin) {
        children.addAll([
          EnableProviderCard(network: network),
          const SizedBox(height: 16),
          const NodeSetupCard(),
          const SizedBox(height: 16),
        ]);
      } else {
        // No set-up card here, deliberately. Installing an engine needs no grid
        // permission, so it *could* be offered — but on a grid you can't share
        // on, a multi-GB download prepares you for something you still can't do,
        // and it read as the page's main call to action while the actual way
        // forward (a grid of your own) sat beside it. [SharingLockedView] now
        // carries the single next step instead.
        children.addAll([
          SharingLockedView(network: network),
          const SizedBox(height: 16),
        ]);
      }
      return children;
    }

    // What this computer is contributing, above everything else: the tab's whole
    // reason to exist, previously answerable only by reading the entire page.
    final startingHere =
        run is ProviderRunActive &&
        run.grid == network.networkId &&
        run.starting;
    children.add(
      ContributionSummary(
        engines: serving,
        gridName: network.name,
        starting: startingHere,
      ),
    );

    // Something broke — it goes directly under the summary, above everything
    // optional. It used to sit below the auto-routing card, which put a feature
    // that announces it has nothing to route *between* "you're sharing nothing"
    // and the reason why. Bad news first, then the offers.
    if (run is ProviderRunFailed) {
      children.addAll([
        EngineFailureCard(
          message: run.message,
          engineLabel: run.model,
          // Clears the failed state so the add forms come back; the user then
          // starts from the block they meant to use. We can't replay the exact
          // join here — the controller doesn't retain its arguments — and
          // guessing which engine to restart would be worse than asking.
          onRetry: () =>
              ref.read(providerRunControllerProvider.notifier).clearFailure(),
          onReinstallEngine: () =>
              ref.read(engineSetupControllerProvider.notifier).run(),
        ),
        const SizedBox(height: 16),
      ]);
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
    if (serving.isNotEmpty || startingHere) {
      children.addAll([
        ServingEnginesSection(network: network),
        const SizedBox(height: 16),
      ]);
    }

    children.addAll(_addEngineBlocks(network, serving));

    // Auto-routing used to sit here. It has moved to the grid's own Overview
    // (Grids tab), because it is a property of the *grid*, not of this computer:
    // every router command carries `--grid <id>` and none carries a node, so
    // turning it on here changed how every machine on the grid is routed and
    // outlived this app being closed. On a page called "This computer", where
    // everything else stops when the machine does, it was the one control that
    // didn't — and once the add-engine paths became tabs, it had to repeat under
    // all three, which is what made the mismatch visible.
    children.add(const SizedBox(height: 16));
    return children;
  }

  /// The ways to add an engine, gated by what this computer is already doing.
  ///
  /// Hosted engines (`--api`) cost this machine nothing, so they stack onto its
  /// union (ADR 0010); only a model it already serves is off the table, which
  /// [ApiEngineBlock] handles per model. Everything that *runs here* competes
  /// for the same GPU and memory, so the machine serves **one** of those at a
  /// time ([connectBlockedReason]):
  ///  - built-in local already running → it must run alone (ADR 0007 D4), so
  ///    nothing can be added until it's stopped;
  ///  - a connected server already running → the built-in can't join it, and
  ///    another connected one can't either; hosted engines still can.
  ///
  /// When a rule bites, the forms it rules out are **replaced** by one note that
  /// says what's running and what to stop — not left on screen disabled. Cards
  /// that can't do anything still read as things to fill in, and a reason
  /// repeated over each one reads as several problems rather than one.
  List<Widget> _addEngineBlocks(
    NetworkCredential network,
    List<ServingEngine> serving,
  ) {
    // Why this computer can't take another engine of its own right now — null
    // when it still can. From origin's shared rule rather than a local
    // `serving.isNotEmpty` test: the constraint is *on-device* contention, so a
    // grid served only by hosted engines leaves the machine free. The old test
    // blocked the built-in whenever anything at all was serving, including a
    // cloud engine that costs this computer nothing.
    final connectBlocked = connectBlockedReason(serving);

    // The built-in local engine is serving → it's exclusive, so no engine can be
    // added alongside it. No picker here: with nothing addable, a chooser would
    // offer three doors that are all shut.
    if (serving.any((engine) => engine.kind == EngineKind.local)) {
      return const [
        AddEngineHeading(),
        SizedBox(height: 8),
        LocalEngineExclusiveNote(),
      ];
    }

    // Windows has no built-in engine yet, so it isn't offered as a choice at
    // all — a pill that can never be picked on this platform is worse than one
    // that isn't there.
    final kinds = Platform.isWindows
        ? const [AddEngineKind.cloud, AddEngineKind.own]
        : AddEngineKind.values;

    // Selectable, but blocked right now. Both on-device paths share one reason,
    // in origin's single voice — the built-in and a connected server compete for
    // the same machine, so whichever is holding it is named once.
    final unavailable = <AddEngineKind, String>{
      if (connectBlocked != null) ...{
        if (!Platform.isWindows) AddEngineKind.local: connectBlocked,
        AddEngineKind.own: connectBlocked,
      },
    };

    // A kind can stop being offered while it's selected (an engine starts on
    // another path, or the platform list is shorter) — fall back rather than
    // render an empty body.
    final selected = kinds.contains(_adding) ? _adding : kinds.first;

    // Engines already up on this machine. Surfaced on the pill because the
    // chooser would otherwise hide them behind a tab nobody has a reason to
    // open — the stacked layout showed a running Ollama unprompted.
    // Counts exactly what the "Your own server" tab renders — `isExternal`, not
    // `isExternal && running`. An installed-but-stopped Ollama still gets a card
    // there (offering to start it), so filtering on `running` here showed a tab
    // with one card behind a pill claiming none.
    final detected =
        ref
            .watch(backendsProvider)
            .asData
            ?.value
            .where((b) => b.isExternal)
            .length ??
        0;

    return [
      // No "Add an engine" heading here: the picker directly below is the
      // control that says so, and a label plus three labelled pills said it
      // twice. The exclusive-local branch above keeps the heading — it has no
      // picker to speak for it.
      AddEnginePicker(
        value: selected,
        kinds: kinds,
        unavailable: unavailable,
        badges: {if (detected > 0) AddEngineKind.own: detected},
        onChanged: (kind) => setState(() => _adding = kind),
      ),
      const SizedBox(height: 14),
      ..._addEngineBody(
        network,
        selected,
        connectBlocked: connectBlocked,
        // Hosted engines don't hold the machine, but the built-in still can't
        // join them — the middle state between "free" and "blocked".
        hostedServing: serving.isNotEmpty,
      ),
    ];
  }

  /// The one open form, for the picked kind. Only this part changes when the
  /// selection changes — the picker above it stays put.
  List<Widget> _addEngineBody(
    NetworkCredential network,
    AddEngineKind kind, {
    required String? connectBlocked,
    required bool hostedServing,
  }) {
    switch (kind) {
      case AddEngineKind.cloud:
        // Hosted engines cost this machine nothing, so they stack however many
        // are running — connectBlocked never gates this path.
        return [ApiEngineBlock(network: network, headerless: true)];

      case AddEngineKind.local:
        if (Platform.isWindows) return const [BuiltInUnavailableNote()];
        // Something is already holding this computer. One note, naming it, in
        // origin's single voice — rather than each blocked path inventing its
        // own sentence for the same fact.
        if (connectBlocked != null) {
          return [OneEngineHereNote(reason: connectBlocked)];
        }

        // Only hosted engines are serving. Nothing is holding the machine, so
        // connectBlocked is null — but the built-in still can't join them
        // (ADR 0007 D4), while a local model behind its own server can. Origin's
        // third state, and dropping it would have shown a form that fails.
        if (hostedServing) return const [LocalNeedsConnectNote()];

        // This computer can't run a model yet — no engine, or no model on disk.
        // Show *only* the set-up card: ServeLocalCard's own "Set up built-in
        // engine" prompt was appearing directly above it, so the tab offered two
        // blue buttons for the same goal. Worse, the upper one installs the
        // engine alone and leaves you still unable to serve, while the card
        // below fetches the engine *and* a model. The narrower fix was leading.
        final plan = ref.watch(nodeCapabilitiesProvider).asData?.value;
        if (plan != null && buildSetupPlan(plan).isNotEmpty) {
          return const [NodeSetupCard()];
        }

        return [
          EngineBlock(
            // Same as the cloud block: the pill above says "This computer" and
            // its hint says what that means.
            headerless: true,
            icon: Icons.dns_outlined,
            title: 'Local Engine',
            subtitle: 'Run a downloaded model on this computer with Llama.cpp.',
            trailing: const EngineCostChip(cost: EngineCost.free),
            child: ServeLocalCard(network: network),
          ),
        ];

      case AddEngineKind.own:
        // A connected server runs here too, so it competes for the same machine
        // as the built-in — origin's rule blocks both, with the same sentence.
        if (connectBlocked != null) {
          return [OneEngineHereNote(reason: connectBlocked)];
        }
        return [_ExternalServers(network: network)];
    }
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
    return EngineSurface(
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
