import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';

import '../../../core/app_environment.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/engine_setup_controller.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../network/presentation/sharing_locked_view.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/engine_slots.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'add_engine_cards.dart';
import 'engine_block.dart';
import 'contribution_summary.dart';
import 'engine_failure_card.dart';
import 'grid_scope_bar.dart';
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

    // Names the grid every sentence below is about, and switches it — but only
    // in a developer build, where several grids are open at once and which one
    // is selected is a thing to check. A shipped user has one grid and no Grids
    // tab beside it, so the strip asks them to hold a distinction they never
    // make.
    // TODO(BE): with it hidden, nothing on this page names the grid (Settings
    // mounts no top bar) and the only switcher left in a release build is the
    // Chat composer's model pill.
    final children = <Widget>[
      if (AppEnvironment.isDeveloperMode) ...[
        GridScopeBar(network: network),
        const SizedBox(height: 16),
      ],
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
    // A stop this machine asked for is still running `grid leave`. It keeps the
    // serving card on screen — the card is what says "Stopping…" — and keeps the
    // add-engine cards away, so a new join can't race the leave.
    final stoppingHere =
        run is ProviderRunStopping && run.grid == network.networkId;
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
    if (serving.isNotEmpty || startingHere || stoppingHere) {
      children.addAll([
        ServingEnginesSection(network: network),
        const SizedBox(height: 16),
      ]);
    }

    children.addAll(
      _addEngineBlocks(network, serving, startingHere || stoppingHere),
    );

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

  /// The ways to add an engine — one card each, in the same words the first-run
  /// screen uses ([AddEngineCards]).
  ///
  /// A computer shares **one** engine ([canAddEngine]), so the cards only appear
  /// while nothing is serving. Once something is, the section is simply absent —
  /// the serving card above is the whole story, and its Stop button is the way
  /// to a different engine. The same goes while a join or a stop is [busy] on
  /// the wire: a card pressed now would race the CLI call already running.
  List<Widget> _addEngineBlocks(
    NetworkCredential network,
    List<ServingEngine> serving,
    bool busy,
  ) => busy || !canAddEngine(serving)
      ? const []
      : [AddEngineCards(network: network)];
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
