import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/share_page_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/engine_setup_controller.dart';
import '../../network/presentation/enable_provider_card.dart';
import '../../network/presentation/sharing_locked_view.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/provider_run_controller.dart';
import '../../../shared/widgets/selectable_body.dart';
import '../logic/serving_engines_provider.dart';
import '../logic/share_route.dart';
import '../logic/share_route_offer.dart';
import 'engine_block.dart';
import 'engine_failure_card.dart';
import 'share_route_detail.dart';
import 'share_route_rail.dart';

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

    return const _ShareIntelligencePage();
  }
}

/// Share Intelligence: the three ways in on the left, the one being set up on
/// the right.
///
/// The only section view that does not sit in [SectionScaffold], and the reason
/// is the rail. That frame draws a page title and a rule across the top, which
/// is the right shape when a page is one column of content — but here the
/// heading, the machine's status and the route picker are *one* thing running
/// down the left, and a second title above them said "Share Intelligence" over
/// a rail whose own first line already says what the page is for. The top bar
/// button that opens this page carries the name.
class _ShareIntelligencePage extends ConsumerWidget {
  const _ShareIntelligencePage();

  /// Below this the two panes stop being two: the design's 396px rail beside a
  /// form is most of a narrow window, and both halves end up too tight to read.
  /// Desktop windows get dragged small (§4), so the layout has to have an
  /// answer.
  static const double _splitAt = 940;

  /// The mockup's field: a visible 1px rim at radius 9 on a light fill, where
  /// the app's own idiom is a borderless capsule at radius 12. Hung over the
  /// page so every field inside it — the model picker, both name boxes, the API
  /// key, the endpoint — picks the design up without seven widgets each growing
  /// a parameter for it.
  static FieldSkin get _fieldSkin => FieldSkin(
    fill: SharePalette.fieldFill,
    rim: SharePalette.fieldRim,
    radius: ShareMetrics.fieldRadius,
    // 38px tall at 13.5px text, which is the design's field.
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    hintSize: 13.5,
    labelStyle: ShareType.fieldLabel,
    showHelp: false,
    slimChevron: true,
  );

  /// The design's buttons and links, for the whole page at once.
  ///
  /// Material reads these from the theme, so one override here reaches
  /// `FilledButton`, `EngineStartButton` and every `TextButton.icon` in the
  /// forms — including the ones inside widgets this page does not own.
  ThemeData _pageTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: SharePalette.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, ShareMetrics.buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShareMetrics.fieldRadius),
          ),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: AppFont.semibold,
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: SharePalette.accent,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(0, 28),
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: AppFont.semibold,
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) return const _NoGridYet();

    // Sharing on THIS grid is locked (an admin hasn't turned engines on; a
    // consumer isn't allowed to). Installing the engine still needs no grid
    // permission, so offer the set-up instead of a wall — then stop here, since
    // a join would be rejected until sharing is on.
    //
    // An admin sees the one-tap fix ([EnableProviderCard] grants itself the
    // role); everyone else gets [SharingLockedView], which explains what they
    // *can* do here. The two gates read different axes on purpose — see the
    // note on `NetworkCredential.isProvider` vs `.role`.
    if (!network.isProvider) return _LockedPage(network: network);

    return Theme(
      data: _pageTheme(context),
      child: FieldSkinScope(
        skin: _fieldSkin,
        child: ColoredBox(
          color: SharePalette.pageBg,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final rail = _RailPane(network: network);
              final detail = _DetailPane(network: network);
              if (constraints.maxWidth < _splitAt) {
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Bounded, because a rail that is a whole scrolling
                      // column has no bottom to pin its footnote to.
                      SizedBox(height: 520, child: rail),
                      Divider(height: 1, color: SharePalette.rim),
                      SizedBox(height: constraints.maxHeight, child: detail),
                    ],
                  ),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: ShareMetrics.railWidth, child: rail),
                  VerticalDivider(width: 1, color: SharePalette.rim),
                  Expanded(child: detail),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The rail, with the page's own padding and its slightly recessed ground.
class _RailPane extends ConsumerWidget {
  const _RailPane({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serving = ref.watch(servingEnginesProvider);
    final run = ref.watch(providerRunControllerProvider);
    return ColoredBox(
      color: SharePalette.railBg,
      child: Padding(
        padding: ShareMetrics.railPadding,
        child: ShareRouteRail(
          network: network,
          offers: shareRouteOffers(ref),
          route: shareRoute(ref),
          live: serving.isNotEmpty,
          starting: _startingHere(run, network) || _stoppingHere(run, network),
        ),
      ),
    );
  }
}

/// The detail pane: whatever this computer's state actually is, in the order
/// that state has to be read — what broke, what is in the way, what is running,
/// and only then the route being set up.
class _DetailPane extends ConsumerWidget {
  const _DetailPane({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serving = ref.watch(servingEnginesProvider);
    final run = ref.watch(providerRunControllerProvider);
    final busy = _startingHere(run, network) || _stoppingHere(run, network);

    return Padding(
      padding: ShareMetrics.panePadding,
      child: switch (run) {
        // Bad news first: a failure is the only thing on this page that the
        // reader cannot act on anywhere else.
        ProviderRunFailed(:final message, :final model) => _FailurePane(
          message: message,
          engineLabel: model,
        ),
        // An engine on ANOTHER grid: remote has one identity per grid, so
        // starting one here would leave that one. Say so before offering a
        // form that would do it silently.
        ProviderRunActive(:final grid) when grid != network.networkId =>
          _EngineBusyElsewhere(runningGridId: grid),
        _ when serving.isNotEmpty || busy => LiveShareDetail(network: network),
        _ => ShareRouteDetail(
          network: network,
          offers: shareRouteOffers(ref),
          route: shareRoute(ref),
        ),
      },
    );
  }
}

bool _startingHere(ProviderRunState run, NetworkCredential network) =>
    run is ProviderRunActive && run.grid == network.networkId && run.starting;

bool _stoppingHere(ProviderRunState run, NetworkCredential network) =>
    run is ProviderRunStopping && run.grid == network.networkId;

/// The routes this machine can take, read once so the rail and the pane can
/// never disagree about which route is which number.
List<ShareRouteOffer> shareRouteOffers(WidgetRef ref) {
  final caps = ref.watch(nodeCapabilitiesProvider).asData?.value;
  return buildShareRouteOffers(
    canRunLocal: ref.watch(supportsBuiltInEngineProvider),
    needsSetup: caps != null && buildSetupPlan(caps).isNotEmpty,
    apiEngines: ref.watch(apiEnginesProvider).asData?.value ?? const [],
    backends: ref.watch(backendsProvider).asData?.value ?? const [],
  );
}

/// The route on show: the reader's pick while it is still on offer, else the
/// default for this machine.
///
/// The guard is not theoretical — a key provider disappears when the CLI is
/// swapped underneath a running app, and a route selected out of a list it is
/// no longer in would leave the pane showing a form the rail has no card for.
ShareRoute shareRoute(WidgetRef ref) {
  final offers = shareRouteOffers(ref);
  final picked = ref.watch(shareRouteProvider);
  if (picked != null && offers.any((offer) => offer.route == picked)) {
    return picked;
  }
  return defaultShareRoute(
    canRunLocal: offers.any((offer) => offer.route == ShareRoute.local),
    serverFound: offers.any(
      (offer) => offer.route == ShareRoute.server && offer.detected > 0,
    ),
    hasKeyProvider: offers.any((offer) => offer.route == ShareRoute.key),
  );
}

/// A failure, and the two ways out of it.
class _FailurePane extends ConsumerWidget {
  const _FailurePane({required this.message, required this.engineLabel});

  final String message;
  final String? engineLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SingleChildScrollView(
    // Inside the scroll view, never around it — see [SelectableBody]. Ported
    // by hand from main's `93e30c91`, which wrapped the page body this branch
    // had already replaced.
    child: SelectableBody(
      child: EngineFailureCard(
        message: message,
        engineLabel: engineLabel,
        // Clears the failed state so the routes come back; the user then starts
        // from the one they meant to use. We can't replay the exact join here —
        // the controller doesn't retain its arguments — and guessing which engine
        // to restart would be worse than asking.
        onRetry: () =>
            ref.read(providerRunControllerProvider.notifier).clearFailure(),
        onReinstallEngine: () =>
            ref.read(engineSetupControllerProvider.notifier).run(),
      ),
    ),
  );
}

/// The page for a grid this user cannot share on.
class _LockedPage extends StatelessWidget {
  const _LockedPage({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: SingleChildScrollView(
      child: SelectableBody(
        child: network.role == NetworkRole.admin
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EnableProviderCard(network: network),
                  const SizedBox(height: 16),
                  const NodeSetupCard(),
                ],
              )
            // No set-up card here, deliberately. Installing an engine needs no
            // grid permission, so it *could* be offered — but on a grid you can't
            // share on, a multi-GB download prepares you for something you still
            // can't do, and it read as the page's main call to action while the
            // actual way forward (a grid of your own) sat beside it.
            : SharingLockedView(network: network),
      ),
    ),
  );
}

/// What the page shows with no grid picked — the one state where nothing here
/// can be set up.
///
/// A sentence naming a tab is what this was, and it named the wrong one for as
/// long as Grids was developer-only: the tab it pointed at wasn't in a shipped
/// build's nav. A button can't go stale that way, and §5 asks every empty state
/// to carry its own next step.
class _NoGridYet extends ConsumerWidget {
  const _NoGridYet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Pick a grid before setting up an engine here.'),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.grids),
            child: const Text('Choose a grid'),
          ),
        ],
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
    return SingleChildScrollView(
      child: SelectableBody(
        child: EngineSurface(
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
                          'You can run an engine on only one grid at a time. '
                          'Stop it to start one on this grid.',
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
      ),
    );
  }
}
