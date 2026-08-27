import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/share_page_theme.dart';
import '../../../shared/widgets/selectable_body.dart';
import '../../messaging/presentation/remote_reach_row.dart';
import '../logic/share_route.dart';
import '../logic/share_route_offer.dart';

/// The left half of Share Intelligence: what this page is for, what this
/// computer is doing about it right now, and the three ways in.
///
/// It is a rail rather than a header because the three routes are a *choice*,
/// and a choice reads as one when its options sit side by side and stay put.
/// Stacked disclosures made the reader open an option to find out what it was,
/// which is the wrong way round: the point of the description on each card is
/// that it can be compared without opening anything.
class ShareRouteRail extends ConsumerWidget {
  const ShareRouteRail({
    super.key,
    required this.network,
    required this.offers,
    required this.route,
    required this.live,
    required this.starting,
  });

  final NetworkCredential network;

  /// The routes this machine can actually take, already worded from what was
  /// found on it.
  final List<ShareRouteOffer> offers;

  /// The route the detail pane is showing.
  final ShareRoute route;

  /// Something is serving on this grid, so no route can be started until it
  /// stops. The cards stay on screen and stop responding: removing them would
  /// take away the only place that says what the alternatives *were*.
  final bool live;
  final bool starting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Scrolls as one column, with the footnote pushed to the bottom whenever
    // there is room for it there. Only the card list scrolled at first, which
    // is what a pinned footnote usually costs: on a short window the last route
    // was cut through the middle of its own sentence, and a half-drawn card
    // reads as a broken page rather than as a list that continues.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        // Inside the scroll view, never around it — see [SelectableBody].
        child: SelectableBody(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RailHeader(gridName: network.name),
                  const SizedBox(height: ShareMetrics.railGap),
                  _SharingStatus(live: live, starting: starting),
                  // Nothing at all unless a bot is connected. It belongs beside
                  // the sharing status and nowhere else on this page: both answer
                  // "what is this computer doing while nobody is at it".
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: RemoteReachRow(),
                  ),
                  const SizedBox(height: ShareMetrics.railGap),
                  Text(
                    live ? 'WAYS TO SHARE' : 'CHOOSE A ROUTE',
                    style: ShareType.eyebrow,
                  ),
                  const SizedBox(height: 8),
                  for (final offer in offers) ...[
                    _RouteCard(
                      offer: offer,
                      selected: !live && offer.route == route,
                      enabled: !live && !starting,
                      onPressed: () {
                        ref
                            .read(analyticsProvider)
                            .addEngineOption(offer.route.name);
                        ref.read(shareRouteProvider.notifier).pick(offer.route);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  const Spacer(),
                  const SizedBox(height: 18),
                  const _RailFootnote(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the page is for, in the reader's terms rather than the product's.
class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.gridName});

  final String gridName;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        // Broken where the design breaks it, not where the rail happens to run
        // out: "Put this computer" over "to work." is the shape that was drawn,
        // and it survives a font this app does not ship.
        'Put this computer\nto work.',
        style: ShareType.railTitle,
      ),
      const SizedBox(height: 9),
      Text(
        // Names the grid, because every sentence on this page is about it, and
        // says the choice is reversible before it is made — the thing that
        // stops a first-time reader hunting for the "right" answer.
        'Answer questions for $gridName using hardware and keys you '
        'already own. Pick a route below. You can change it any time.',
        style: ShareType.railBody,
      ),
    ],
  );
}

/// Whether this computer is reachable from the grid, said plainly.
///
/// It reports; it never offers. The Stop button lives with the engine it stops,
/// in the detail pane, so there is exactly one place to end a session.
class _SharingStatus extends StatelessWidget {
  const _SharingStatus({required this.live, required this.starting});

  final bool live;
  final bool starting;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final (title, note) = switch ((live, starting)) {
      (true, _) => (
        'Sharing, live now',
        'Requests are reaching this computer.',
      ),
      (false, true) => (
        'Starting an engine',
        'It shows here as soon as it is serving.',
      ),
      (false, false) => (
        'Not sharing yet',
        'Nothing on this computer is reachable from the grid.',
      ),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: SharePalette.surface,
        borderRadius: BorderRadius.circular(ShareMetrics.statusRadius),
        border: Border.all(color: SharePalette.rim),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Breathing only while something is actually happening — a halo on an
          // idle machine reports activity there isn't any of.
          _PulseDot(
            colour: live ? SharePalette.liveDot : SharePalette.idleDot,
            pulsing: live || starting,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ShareType.statusTitle),
                const SizedBox(height: 2),
                Text(note, style: ShareType.note),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 7px dot beside the sharing status, breathing while something is live.
///
/// Not [StatusDot]: that one is 9px with a glow behind it, drawn for a row in a
/// list. The design's is a plain 7px circle that pulses by fading and shrinking
/// on a 2.4s ease — a slower, smaller signal, sized for a block of text rather
/// than a table.
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.colour, required this.pulsing});

  final Color colour;
  final bool pulsing;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion gets the dot, not the breathing: the colour already carries
    // the whole message (§11).
    final still = !widget.pulsing || MediaQuery.of(context).disableAnimations;
    if (still) {
      _beat.stop();
      _beat.value = 0;
      return;
    }
    if (!_beat.isAnimating) _beat.repeat();
  }

  @override
  void didUpdateWidget(_PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) didChangeDependencies();
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: AnimatedBuilder(
      animation: _beat,
      builder: (context, child) {
        // 0 → 1 → 0 over the turn, which is the CSS keyframe's shape: full at
        // both ends, weakest in the middle.
        final swing = (0.5 - (_beat.value - 0.5).abs()) * 2;
        return Opacity(
          opacity: 1 - 0.65 * swing,
          child: Transform.scale(scale: 1 - 0.15 * swing, child: child),
        );
      },
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: widget.colour, shape: BoxShape.circle),
      ),
    ),
  );
}

/// One route to press: what it is, and one line of how.
///
/// It wore a two-word benefit badge for a while — "Private", "Instant", "1
/// found" — on the argument that three cards compare faster down one column of
/// chips than across three sentences. They went: the sentence under each title
/// already says the same thing in words the reader does not have to decode, and
/// three chips down the right edge of a rail is three more things competing
/// with the one that is selected.
class _RouteCard extends StatefulWidget {
  const _RouteCard({
    required this.offer,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final ShareRouteOffer offer;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<_RouteCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final offer = widget.offer;
    final selected = widget.selected;

    return Opacity(
      // Dimmed rather than removed while an engine serves: the cards are the
      // only place that says what the other two routes were, and a reader who
      // presses Stop should find the page where they left it.
      opacity: widget.enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: SharePalette.surface,
              borderRadius: BorderRadius.circular(ShareMetrics.cardRadius),
              border: Border.all(
                color: selected
                    ? SharePalette.accent
                    : _hovered && widget.enabled
                    ? SharePalette.fieldRim
                    : SharePalette.rim,
              ),
              // A ring, not a heavier border: the selected card has to be
              // findable at a glance without the row growing by a pixel and
              // shifting the two under it.
              boxShadow: selected
                  ? [BoxShadow(color: SharePalette.accentRing, spreadRadius: 3)]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A fixed gutter, so the three titles start on one line however
                // wide their glyphs are.
                SizedBox(
                  width: 26,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      _routeIcon(offer.route),
                      size: 22,
                      color: selected ? SharePalette.accent : SharePalette.line,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(offer.title, style: ShareType.cardTitle),
                      const SizedBox(height: 3),
                      Text(offer.line, style: ShareType.cardLine),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The glyph for a route. Kept beside the card that draws it: [ShareRouteOffer]
/// is what the machine has to offer, and an [IconData] in it would put Material
/// in a logic file for the sake of three constants.
IconData _routeIcon(ShareRoute route) => switch (route) {
  ShareRoute.local => Icons.computer_outlined,
  ShareRoute.key => Icons.key_outlined,
  ShareRoute.server => Icons.dns_outlined,
};

/// The two facts a host should have before they start, not after.
class _RailFootnote extends StatelessWidget {
  const _RailFootnote();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, thickness: 1, color: SharePalette.footRule),
        const SizedBox(height: 18),
        Text(
          // "Keys stay in your keychain" is what the design said here, and this
          // app has no keychain — a key goes to the local `grid` CLI. The
          // promise the app can actually keep is the one the API form already
          // makes, in its words (§5).
          'Sharing stops the moment you close the lid, quit Grid, or press '
          'stop. A key you paste never leaves this computer.',
          style: ShareType.footnote,
        ),
      ],
    );
  }
}
