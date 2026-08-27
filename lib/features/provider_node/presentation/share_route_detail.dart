import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/share_page_theme.dart';
import '../../models/presentation/serve_local_card.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../node_setup/presentation/node_setup_card.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/api_engine_choices.dart';
import '../logic/serving_engines_provider.dart';
import '../logic/share_route.dart';
import '../logic/share_route_offer.dart';
import 'api_engine_block.dart';
import 'external_servers.dart';
import 'serving_engines_section.dart';

/// The right half of Share Intelligence: the route picked on the left, said
/// once at the top and then set up underneath.
///
/// One route at a time, which is the whole reason the page split in two. The
/// forms it shows are the same ones the stacked rows used to open — they were
/// never the problem; being three-deep inside disclosures was.
class ShareRouteDetail extends ConsumerWidget {
  const ShareRouteDetail({
    super.key,
    required this.network,
    required this.offers,
    required this.route,
  });

  final NetworkCredential network;
  final List<ShareRouteOffer> offers;
  final ShareRoute route;

  /// Which of the offered routes this is, one-based. Read off the rail's own
  /// list rather than written into the copy: a machine that cannot run a local
  /// engine has no route 01, and an eyebrow saying otherwise would number a
  /// row that is not on the page.
  int get _position => offers.indexWhere((offer) => offer.route == route) + 1;

  /// How many engines were detected here, read off the badge the rail already
  /// draws, so the paragraph and the card can never disagree about the count.
  int get _serversFound {
    final server = offers
        .where((offer) => offer.route == ShareRoute.server)
        .firstOrNull;
    final badge = server?.badge;
    if (badge == null) return 0;
    return int.tryParse(badge.split(' ').first) ?? 0;
  }

  String get _foundPhrase =>
      _serversFound == 1 ? 'one engine' : '$_serversFound engines';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final (eyebrow, title, blurb) = switch (route) {
      ShareRoute.local => (
        'LOCAL MODEL',
        'Run a model on this computer.',
        'Questions arrive over the grid, get answered on your hardware, and '
            'the answer goes back. The weights never leave this disk.',
      ),
      ShareRoute.key => (
        'YOUR OWN KEY',
        'Lend a key, not a machine.',
        'Grid forwards questions to the provider you pick, using your key. '
            'The key stays on this computer, and what it spends is billed to '
            'your account.',
      ),
      ShareRoute.server => (
        'EXISTING SERVER',
        "Share what's already running.",
        // Names the count when there is one to name — the design's sentence —
        // and falls back to the general one when nothing was detected, where
        // "Grid found one engine" would be a plain untruth (§5).
        _serversFound == 0
            ? 'Point Grid at an engine on this computer and your existing '
                  'setup is shared exactly as configured: models, '
                  'quantization, flags.'
            : 'Grid found $_foundPhrase on this computer. Point at it and '
                  'your existing setup is shared exactly as configured: '
                  'models, quantization, flags.',
      ),
    };

    return _PaneColumn(
      children: [
        PanelHeader(
          eyebrow: 'ROUTE 0$_position · $eyebrow',
          title: title,
          blurb: blurb,
        ),
        const SizedBox(height: ShareMetrics.paneGap),
        Expanded(
          child: SingleChildScrollView(
            child: switch (route) {
              ShareRoute.local => _LocalRoute(network: network),
              ShareRoute.key => _KeyRoute(network: network),
              ShareRoute.server => ExternalServers(network: network),
            },
          ),
        ),
      ],
    );
  }
}

/// A pane's content, filling the half of the page it was given.
///
/// The design holds it to a 720px measure, which is the right call on its own
/// canvas — that mock has no app sidebar, so 720 *is* most of the pane. Here
/// the sidebar takes 280 of the window before this page starts, and the same
/// cap left a plate floating in a field of empty ground on any window wider
/// than about 1200. The pane's own padding is the measure now.
class _PaneColumn extends StatelessWidget {
  const _PaneColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

/// What the pane is about, before anything it asks for.
///
/// Public because the live pane needs the same three lines in the same sizes,
/// and two headers a screen apart drifting by a point is exactly the kind of
/// thing nobody sees until the screenshots sit side by side.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.blurb,
    this.eyebrowColour,
  });

  final String eyebrow;
  final String title;
  final String blurb;
  final Color? eyebrowColour;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: eyebrowColour == null
              ? ShareType.eyebrow
              : ShareType.eyebrow.copyWith(color: eyebrowColour),
        ),
        const SizedBox(height: 7),
        Text(title, style: ShareType.paneTitle),
        const SizedBox(height: 7),
        Text(blurb, style: ShareType.paneBody),
      ],
    );
  }
}

/// The local engine: install it first if this machine still needs it, then the
/// serve form.
///
/// The install is not a step the reader chooses — it is what this route costs
/// on a machine that has never served. So the button says what it is for, and
/// the progress replaces it in place rather than opening somewhere else.
class _LocalRoute extends ConsumerStatefulWidget {
  const _LocalRoute({required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<_LocalRoute> createState() => _LocalRouteState();
}

class _LocalRouteState extends ConsumerState<_LocalRoute> {
  /// Whether the user has asked for the install on this visit. The serve form
  /// opens behind it, so the moment the download lands they are looking at the
  /// model picker rather than a finished checklist.
  bool _setUpAsked = false;

  Future<void> _setUp() async {
    final caps = await ref.read(nodeCapabilitiesProvider.future);
    if (!mounted) return;
    setState(() => _setUpAsked = true);
    await ref
        .read(nodeSetupControllerProvider.notifier)
        .run(buildSetupPlan(caps));
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(nodeCapabilitiesProvider).asData?.value;
    final needsSetup = caps != null && buildSetupPlan(caps).isNotEmpty;
    final setup = ref.watch(nodeSetupControllerProvider);

    return switch (setup) {
      NodeSetupRunning() ||
      NodeSetupFailed() => const NodeSetupCard(framed: false),
      _ when needsSetup && !_setUpAsked => _SetUpFirst(onPressed: _setUp),
      _ => ServeLocalCard(network: widget.network),
    };
  }
}

/// The one press this route needs before it can show a form.
class _SetUpFirst extends StatelessWidget {
  const _SetUpFirst({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'This computer needs the built-in engine before it can run a '
          'model. It downloads once and takes a few minutes.',
          style: ShareType.paneBody,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Set up the engine'),
        ),
      ],
    );
  }
}

/// The API-key route. The provider list is read here so the form is never
/// drawn with nothing to offer.
class _KeyRoute extends ConsumerWidget {
  const _KeyRoute({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = keyEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const <ApiEngine>[],
    );
    if (engines.isEmpty) return const SizedBox.shrink();
    return ApiEngineForm(
      network: network,
      engines: engines,
      // The pane above already carries the header and the explanation, so the
      // form keeps its full detail without repeating either.
      compact: false,
    );
  }
}

/// What the pane shows once this computer is actually serving.
///
/// The stat panel the design drew here — requests, tokens out, uptime, median
/// latency — is not built: nothing in this app measures any of the four for
/// *this* machine, and four figures invented to fill a grid is the one thing a
/// dashboard must never do (§5). What is real sits below instead: the engines,
/// each stoppable, from [ServingEnginesSection].
///
/// TODO(BE): the grid overview *does* carry per-node answered totals
/// (`answeredTokensMetric` and friends, with a real "unmeasured" state). Making
/// them this computer's would mean matching `NetworkCredential.nodeId` to an
/// `OverviewNode`, which nothing in the app does yet.
class LiveShareDetail extends ConsumerWidget {
  const LiveShareDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final models = {
      for (final engine in ref.watch(servingEnginesProvider)) ...engine.models,
    };
    final what = switch (models.length) {
      0 => 'Serving on ${network.name}',
      1 => 'Serving ${models.first} on ${network.name}',
      final n => 'Serving $n models on ${network.name}',
    };
    return _PaneColumn(
      children: [
        PanelHeader(
          eyebrow: 'LIVE ON THE GRID',
          eyebrowColour: SharePalette.liveInk,
          title: 'This computer is answering questions.',
          blurb: '$what. Leave Grid running and it keeps working.',
        ),
        const SizedBox(height: ShareMetrics.paneGap),
        Expanded(
          child: SingleChildScrollView(
            child: ServingEnginesSection(network: network),
          ),
        ),
      ],
    );
  }
}
