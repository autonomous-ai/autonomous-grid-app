import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../../../shared/widgets/status_dot.dart';
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
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RailHeader(gridName: network.name),
                const SizedBox(height: 18),
                _SharingStatus(live: live, starting: starting),
                // Nothing at all unless a bot is connected. It belongs beside
                // the sharing status and nowhere else on this page: both answer
                // "what is this computer doing while nobody is at it".
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: RemoteReachRow(),
                ),
                const SizedBox(height: 18),
                _RailLabel(live ? 'WAYS TO SHARE' : 'CHOOSE A ROUTE'),
                const SizedBox(height: 10),
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
                const SizedBox(height: 14),
                const _RailFootnote(),
              ],
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Put this computer to work.',
          style: theme.textTheme.headlineMedium?.copyWith(height: 1.14),
        ),
        const SizedBox(height: 9),
        Text(
          // Names the grid, because every sentence on this page is about it,
          // and says the choice is reversible before it is made — the thing
          // that stops a first-time reader hunting for the "right" answer.
          'Answer questions for $gridName using hardware and keys you '
          'already own. Pick a route below. You can change it any time.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
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
    final theme = Theme.of(context);
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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: StatusDot(
              color: live ? AppPalette.online : AppPalette.textFaint,
              size: 8,
              // Breathing only while something is actually happening — a halo
              // on an idle machine reports activity there isn't any of.
              pulsing: live || starting,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppFont.semibold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The small capitalised label over a group in the rail.
class _RailLabel extends StatelessWidget {
  const _RailLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      fontWeight: AppFont.semibold,
      letterSpacing: 1.05,
      color: AppPalette.textSecondary,
    ),
  );
}

/// One route to press: what it is, what it saves you, and one line of how.
///
/// The badge carries the benefit in two words so the three cards can be
/// compared down that column alone — "Private", "Instant", "1 found" answer
/// "which of these suits me" faster than three sentences do.
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
    final theme = Theme.of(context);
    final offer = widget.offer;
    final selected = widget.selected;
    final ink = widget.enabled
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

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
              color: AppGlass.surfaceFill,
              borderRadius: BorderRadius.circular(AppCard.radius),
              border: Border.all(
                color: selected
                    ? AppPalette.accent
                    : _hovered && widget.enabled
                    ? AppPalette.textFaint
                    : AppPalette.divider,
              ),
              // A ring, not a heavier border: the selected card has to be
              // findable at a glance without the row growing by a pixel and
              // shifting the two under it.
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppPalette.accent.withValues(alpha: 0.14),
                        spreadRadius: 3,
                      ),
                    ]
                  : AppGlass.cardShadow,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    _routeIcon(offer.route),
                    size: 21,
                    color: selected ? AppPalette.accent : AppPalette.textFaint,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              offer.title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: ink,
                              ),
                            ),
                          ),
                          if (offer.badge != null) ...[
                            const SizedBox(width: 8),
                            BadgePill(
                              label: offer.badge!,
                              color: _badgeColour(offer.badgeTone),
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        offer.line,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textSecondary,
                          height: 1.45,
                        ),
                      ),
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

/// One badge on this page gets a colour: a server already running here, which
/// is the route that is one press from done. The rest stay neutral, because a
/// rail where every pill is bright has nothing left to point with.
Color _badgeColour(ShareBadgeTone tone) => switch (tone) {
  ShareBadgeTone.neutral => AppPalette.textSecondary,
  ShareBadgeTone.ready => AppPalette.online,
};

/// The two facts a host should have before they start, not after.
class _RailFootnote extends StatelessWidget {
  const _RailFootnote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: AppPalette.divider),
        const SizedBox(height: 14),
        Text(
          // "Keys stay in your keychain" is what the design said here, and this
          // app has no keychain — a key goes to the local `grid` CLI. The
          // promise the app can actually keep is the one the API form already
          // makes, in its words (§5).
          'Sharing stops the moment you close the lid, quit Grid, or press '
          'stop. A key you paste never leaves this computer.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
