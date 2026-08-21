import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/member_display.dart';
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/member_usage_provider.dart';
import '../../../features/network/logic/node_groups.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredWindowLabel, formatCount;
import '../../../features/network/presentation/share_grid_dialog.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/member_usage.dart';
import '../../theme/app_theme.dart';
import '../../widgets/member_avatar.dart';
import '../../widgets/skeleton.dart';
import 'pill_panel_shell.dart';

/// The panel behind one figure in the top bar's grid pill: hovering "21 members"
/// names the twenty-one, "8 nodes" the eight machines, "7 models" the seven
/// models, the token figure the four counts it sums.
///
/// The pill's numbers used to be unreadable in the only way that matters — you
/// could see *how many* and never *which*, and the one panel the pill opened
/// answered that for the machines alone. A count is a question; this is where it
/// gets its answer, without leaving the screen you're on.
///
/// The frame only: anchored under its own figure (not the whole pill, so it
/// points at the number it belongs to) and carrying the shared surface. What
/// goes inside is [GridMembersList] / [GridNodesList] / [GridModelsList] /
/// [GridTokensList].
class GridStatPanel extends StatelessWidget {
  const GridStatPanel({
    super.key,
    required this.link,
    required this.anchorKey,
    required this.tapGroupId,
    required this.onEnter,
    required this.onExit,
    required this.child,
    this.width = defaultWidth,
  });

  /// Links to the pill figure this panel belongs under.
  final LayerLink link;

  /// The same figure, as something that can be measured: a [LayerLink] places
  /// the panel but says nothing about *where on screen* it lands, and where it
  /// lands is what decides whether it still fits (see [_slide]).
  final GlobalKey anchorKey;

  /// Shared with the pill so a click inside the panel isn't the "click outside"
  /// that dismisses a pinned one — the panel lives in an overlay, outside the
  /// pill's own subtree.
  final Object tapGroupId;

  final VoidCallback onEnter;
  final VoidCallback onExit;

  final Widget child;

  /// How wide the panel is. The default suits a one-column list of names; the
  /// node list asks for more, since its rows carry a spec line too.
  final double width;

  /// Narrower than the hardware panel: a list of names is one column, and a long
  /// email or model id ellipsizes rather than widening the popover.
  static const double defaultWidth = 298;

  /// The surface's own padding, undone on the left so the list's text sits under
  /// the figure's text rather than being inset from it by a rim's width.
  static const double _inset = 13;

  /// How close to the window's edge the panel may come once it has had to move
  /// to stay on screen.
  static const double _edgeMargin = 10;

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    // Never wider than the window it opens over — a clamp that only bites on a
    // window narrower than any the app can be resized to, but the slide below
    // needs a width it can trust.
    final panelWidth = math.min(width, windowWidth - _edgeMargin * 2);
    return Positioned(
      width: panelWidth,
      child: CompositedTransformFollower(
        link: link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: Offset(-_inset + _slide(windowWidth, panelWidth), 8),
        child: MouseRegion(
          onEnter: (_) => onEnter(),
          onExit: (_) => onExit(),
          child: TapRegion(
            groupId: tapGroupId,
            child: _Entrance(child: PillPanelSurface(child: child)),
          ),
        ),
      ),
    );
  }

  /// How far the panel has to slide sideways to stay inside the window — zero,
  /// the usual case, when it already fits where its figure puts it.
  ///
  /// The pill lives at the *right* end of the top bar, so a panel hung from the
  /// left of its figure and grown rightwards runs off the window's edge, and
  /// the whole right-hand column goes with it: the section's count, and every
  /// machine's memory figure. Sliding beats re-anchoring to the figure's right
  /// edge, which would park the panel well left of the number it belongs to
  /// even when there was room to sit under it.
  double _slide(double windowWidth, double panelWidth) {
    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    final left = box.localToGlobal(Offset.zero).dx - _inset;
    final limit = windowWidth - panelWidth - _edgeMargin;
    return left.clamp(_edgeMargin, math.max(_edgeMargin, limit)) - left;
  }
}

/// The panel arriving: a short fade while it settles the last few pixels down
/// from the capsule it hangs off.
///
/// Six pixels and 160ms, which is under the threshold at which a movement reads
/// as *travel* — the panel should look like it was already there and is coming
/// into focus, not like it flew in. These open on hover, so whatever this costs
/// is paid every time the pointer crosses the pill.
///
/// Only on the way in. There is no exit animation because there is nothing to
/// animate: [OverlayPortal] takes the panel out of the tree the moment it hides,
/// and holding it there to fade would keep a dead popover over the transcript.
///
/// Runs once per mount, so swapping figures under an open panel — members to
/// nodes, name to memory — replaces the contents in place without re-playing
/// this. That swap is a different motion and belongs to whatever is inside.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Reduce Motion means no motion, not less of it — the fade goes too, since
    // an opacity ramp is the part that reads as movement on a surface this size.
    final instant = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: instant ? Duration.zero : AppMotion.swap,
      curve: AppMotion.curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * -6),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Who is on this grid, by email, busiest reader first — the panel behind the
/// pill's member count.
///
/// Two sources, joined here: the roster comes from the control plane (everyone
/// who *may* use the grid) and the usage from the relay (what each of them
/// actually ran in the last 24h). Neither knows the other, so a member who has
/// never sent a request appears with no figure and a consumer the roster has
/// since dropped simply doesn't appear — the roster decides who is listed.
class GridMembersList extends ConsumerStatefulWidget {
  const GridMembersList({super.key, required this.onDismiss});

  /// Closes the panel this list is drawn in. Needed because the list now ends
  /// in an action: a popover held open by the pointer has to get out of the way
  /// once it has handed the user to a dialog, or it hangs behind the barrier
  /// waiting for a hover that will never come back.
  final VoidCallback onDismiss;

  @override
  ConsumerState<GridMembersList> createState() => _GridMembersListState();
}

class _GridMembersListState extends ConsumerState<GridMembersList> {
  /// The address of the row under the pointer, or null when it is on none of
  /// them. Kept here rather than in the row so the detail line — which is not
  /// inside the row — can read it.
  String? _hovered;

  /// Guarded on the *current* hover, not the one leaving: crossing from one row
  /// to the next fires `onExit` for the old after `onEnter` for the new, and
  /// clearing unconditionally would blank the line for a frame on every move
  /// down the list.
  void _onHover(String email, bool over) {
    if (over) {
      if (_hovered != email) setState(() => _hovered = email);
    } else if (_hovered == email) {
      setState(() => _hovered = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(selectedNetworkProvider);
    if (grid == null) return const SizedBox.shrink();
    // Read for its *value*, never to gate the list: the roster is what the panel
    // is for, and blocking the whole thing on a second request would make an
    // already-known roster arrive late. Absent usage degrades to an unranked,
    // unlabelled list rather than to a spinner.
    //
    // The loading flag comes along separately because `.value` alone cannot tell
    // "this grid reports no rollup" from "the call is still out", and the two
    // render differently: an empty figure column against a row of skeleton bars.
    final usageAsync = ref.watch(gridMemberUsageProvider);
    final usage = usageAsync.value;
    final usageLoading = usage == null && usageAsync.isLoading;
    final roster = ref.watch(networkMembersProvider(grid.networkId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        roster.when(
          // The rows in the shape they will land in, rather than a sentence
          // that is one line tall and gets replaced by ten — the panel hangs off
          // a pill in the top bar, so a body that changes height mid-load moves
          // under a pointer that is already on it.
          loading: () => const _MembersSkeleton(),
          // The provider's own message, which is already written for a person
          // ("Sign in to manage members.") rather than a socket error.
          error: (err, _) => PillPanelMessage(text: '$err'),
          data: (members) {
            final byEmail = usage?.byEmail;
            final rows = sortMembersByUsage(
              members,
              byEmail,
              emailOf: (m) => m.email,
            );
            // Whether a mark still tells two rows apart is a fact about the
            // list, not about the person — so the colours are dealt out here,
            // over the whole roster, rather than inside a row that cannot see
            // the ones above it.
            final slots = memberAvatarSlots([
              for (final m in rows) m.email,
            ], AppPalette.avatarPalette.length);
            final hovered = memberUsageFor(byEmail, _hovered ?? '');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _PanelBody(
                  // The count moves into the heading and the figure takes its place:
                  // "how many" is a property of the word it sits beside, while the
                  // right-hand slot is where every other panel puts the total of the
                  // column under it. That total is the sum of the rows SHOWN, so the
                  // column adds up to its own header — it can read lower than the
                  // pill's grid-wide input figure, which also counts people the
                  // roster no longer lists and consumers the relay could not name.
                  label: '${rows.length} members',
                  trailing: usage == null
                      ? null
                      : memberInputTotalLabel(
                          rows.map((m) => memberUsageFor(byEmail, m.email)),
                          usage.windowSeconds,
                        ),
                  emptyText: 'No one is on this grid yet.',
                  itemCount: rows.length,
                  // No note about the *kind* of member. "Work email" sat on most
                  // rows of a work grid and so told the eye nothing — a mark
                  // every row carries stops being a mark. The owner is the one
                  // row worth finding and keeps a chip; the trailing slot now
                  // spends its width on the figure the list is ordered by.
                  itemBuilder: (context, i) => _MemberRow(
                    email: rows[i].email,
                    slot: slots[i],
                    isOwner: rows[i].isOwner,
                    usage: memberUsageFor(byEmail, rows[i].email),
                    usageLoading: usageLoading,
                    hovered: _hovered == rows[i].email,
                    onHover: (over) => _onHover(rows[i].email, over),
                  ),
                ),
                // Only where there is something to point at, or about to be. A
                // grid whose master reports no usage carries no such line at
                // all — it would invite a hover that can never say anything —
                // but one whose figures are merely still coming keeps the block
                // as bars: it appears the moment they land, and a panel that
                // grows a line under a pointer already resting on it is the
                // same jump the skeleton above exists to prevent.
                if (rows.isNotEmpty && (byEmail != null || usageLoading))
                  _MemberDetailLine(usage: hovered, loading: usageLoading),
              ],
            );
          },
        ),
        // The way to add the thirty-fourth person, under the thirty-three
        // already there. This panel is opened to answer "who is on this grid?",
        // and the commonest reason to ask is that somebody is *not* — which the
        // list could state and then leave the user to go hunting through the
        // account menu to act on.
        //
        // Outside the `when`, so it is already drawn while the roster is still
        // coming: a row that appears on load would pull the panel's own bottom
        // edge down past a pointer resting on it, which is the jump the
        // skeleton above exists to prevent.
        //
        // Not on the error branch. That message is usually "Sign in to manage
        // members", and an invite offered to someone the control plane will not
        // answer for is a door onto a second refusal.
        if (!roster.hasError)
          _InviteFooter(
            gridName: grid.name,
            onTap: () {
              // Act first, dismiss second — the same order [_PanelActions]
              // keeps, and for the same reason: `onDismiss` unmounts the widget
              // whose `context` the dialog is still being pushed from.
              ShareGridDialog.show(context, grid);
              widget.onDismiss();
            },
          ),
      ],
    );
  }
}

/// One member: a coloured circle with their initial, their address, their 24h
/// input figure, and the full split on hover.
///
/// **The whole address, weighted.** The column used to print `@dev` and stop —
/// short, but it withheld the one string a person copies, searches for and
/// checks a spelling of, and the leading `@` made every row start with the same
/// character. Now the row prints `dev@autonomous.ai`: the name in the row's own
/// ink, the domain behind it in the faint one. The width the shortening was
/// protecting is still protected, because the ellipsis now falls on the domain
/// — the half of the line every row agrees on.
///
/// Input leads because reading is what a grid is asked to do — output follows
/// from it, and requests count turns rather than work. The other three are a
/// hover away rather than on the row: four numbers per line would leave no room
/// for the name, which is the thing being looked up.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.email,
    required this.slot,
    required this.isOwner,
    required this.usage,
    required this.usageLoading,
    required this.hovered,
    required this.onHover,
  });

  /// The address itself — what this row *is*, and the key everything else about
  /// it is looked up by (the usage map, the hover). Never what it prints.
  final String email;

  /// Which colour this row's circle takes — decided for the roster as a whole
  /// by `memberAvatarSlots`, not here, so no two visible rows match.
  final int slot;

  final bool isOwner;

  /// Whether the pointer is on this row. Owned by the list rather than by the
  /// row, because the line that reports the hovered member is not inside it.
  final bool hovered;
  final ValueChanged<bool> onHover;

  /// Null when the grid reported no rollup, or when this person has run nothing
  /// — the row then prints no figure at all. Deliberately not a `0`: on a grid
  /// whose master is too old to answer, a column of zeros would report everyone
  /// as idle when the truth is that nobody asked.
  final MemberUsage? usage;

  /// Whether the usage call is still out — a *different* reason for [usage] to
  /// be null, and the row says so with a skeleton bar rather than with the empty
  /// column that means "this person has run nothing".
  ///
  /// The roster and the usage come from two systems and land at different times,
  /// so this window is real on every open: the names arrive from the control
  /// plane while the figures are still coming from the relay.
  final bool usageLoading;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = _PanelRow(
      // The whole address, cut in two so the name leads: `dev` in the row's own
      // ink, `@autonomous.ai` behind it in the faint one.
      label: memberLocalPart(email),
      labelSuffix: memberDomainPart(email),
      leading: MemberAvatar(email: email, slot: slot, size: 22, fontSize: 11.5),
      strong: true,
      badge: isOwner ? 'owner' : null,
      // The **fresh** input leg, matching the hover's "input tokens" line and the
      // pill's own figure. Printing `tokensIn` raw here made the row larger than
      // the number the tooltip called input, which reads as a bug rather than as
      // the cache being a share of it.
      trailing: switch (usage) {
        // A figure the grid measured. Null is not "zero" — see [usage].
        final measured? => _PanelFigure(
          text: formatCount(measured.freshInputTokens),
        ),
        null when usageLoading => const _FigureSkeleton(),
        null => null,
      },
    );
    if (usage == null) return row;
    // A `MouseRegion`, never a `Tooltip`. This panel is drawn inside a
    // `CompositedTransformFollower` (it hangs off the pill), and Flutter's
    // Tooltip positions itself with `localToGlobal` — which through a follower
    // layer throws "the paint transform cannot be reliably computed" during
    // layout. The hint never appeared and every hover logged that instead. The
    // detail goes in a line inside the panel, where no overlay is needed.
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hovered ? AppSurface.hoverFill : Colors.transparent,
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
        child: row,
      ),
    );
  }
}

/// The panel's last row: the offer to put someone new on this grid.
///
/// Washed rather than filled, and a row rather than a button. The panel's own
/// action language is a link (`_PanelLink`), and a solid button at the foot of a
/// popover that opens on hover would read as the panel's purpose — this is the
/// thing you reach for once, having read the list above it.
///
/// It names the grid because the panel does not: the heading says "33 MEMBERS",
/// which is true of whichever grid is in scope, and an invite that does not say
/// where it leads is the one mistake this dialog cannot recover from.
class _InviteFooter extends StatefulWidget {
  const _InviteFooter({required this.gridName, required this.onTap});

  final String gridName;
  final VoidCallback onTap;

  @override
  State<_InviteFooter> createState() => _InviteFooterState();
}

class _InviteFooterState extends State<_InviteFooter> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Measured, both themes: `accentOnSurface` on the wash composited over the
    // panel's own `#202020` lands at 4.73:1 in dark and 4.94:1 in light. The
    // washes are 1.12:1 against the panel — a tint, not a second surface, which
    // is what keeps this a row rather than a button.
    final ink = AppPalette.accentOnSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The panel's one rule. §2 allows a menu panel's rim and nothing else,
          // but this parts a list from the action on it — without it the row
          // reads as a thirty-fourth member, washed for no stated reason.
          Divider(height: 1, thickness: 1, color: AppPalette.divider),
          const SizedBox(height: 6),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: AppMotion.hover,
                curve: AppMotion.curve,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                decoration: BoxDecoration(
                  color: _hovered
                      ? AppSurface.accentWashHover
                      : AppSurface.accentWash,
                  borderRadius: BorderRadius.circular(AppControl.radius),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.userPlus300, size: 15, color: ink),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Invite people to ${widget.gridName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: AppFont.medium,
                          color: ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(LucideIcons.chevronRight300, size: 14, color: ink),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The members panel while the roster is still coming: the heading, five rows
/// and the detail block, in the shape they will land in.
///
/// A skeleton rather than "Loading members…" for the reason every list in this
/// app uses one — but with an extra edge here. This panel hangs off a figure in
/// the top bar and stays open only while the pointer is on it or on the pill; a
/// body that is one line tall and then ten pulls the panel's own edges out from
/// under that pointer, which closes the thing you were waiting for.
///
/// Five rows, and their metrics are [_MemberRow]'s exactly — a 22px tile in a
/// row padded by 4 — so nothing shifts sideways or down when the names arrive.
class _MembersSkeleton extends StatelessWidget {
  const _MembersSkeleton();

  /// How many placeholder rows. Enough to read as a list, few enough that a
  /// three-person grid does not shrink dramatically when it loads.
  static const int _rows = 5;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The heading's own line box, held by a bar rather than by the words
        // "N MEMBERS" — the count is the one thing this state cannot know.
        const SizedBox(
          height: 15,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Skeleton.text(width: 78, height: 8),
          ),
        ),
        const SizedBox(height: 10),
        // Fading down the column so the block reads as "more below" rather than
        // as a wall that stops at an arbitrary row — SkeletonList's trick, kept
        // here because these rows are this panel's shape, not its.
        for (var i = 0; i < _rows; i++)
          Opacity(
            opacity: 1 - (i / _rows) * 0.65,
            child: const _MemberSkeletonRow(),
          ),
        const _MemberDetailLine(usage: null, loading: true),
      ],
    );
  }
}

/// One placeholder member: the circle, the handle, the figure.
class _MemberSkeletonRow extends StatelessWidget {
  const _MemberSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Skeleton(width: 22, height: 22, radius: 11),
          SizedBox(width: 9),
          // Not full width: a column of bars all reaching the figure would read
          // as a grey slab rather than as a list of names of differing length.
          Expanded(child: SkeletonLine(widthFactor: 0.72, height: 9)),
          SizedBox(width: 9),
          _FigureSkeleton(),
        ],
      ),
    );
  }
}

/// The hovered member's whole 24h split, under the list — requests, fresh
/// input, cache and output.
///
/// **A line in the panel rather than a tooltip**, because a tooltip cannot work
/// here: this panel is drawn inside a `CompositedTransformFollower` and
/// Flutter's Tooltip needs `localToGlobal`, which throws through a follower
/// layer. Drawn in place, it needs no overlay and no transform.
///
/// Always present once there is usage to point at, and **always exactly two
/// lines**, hovered or not: this is a list you run the pointer down, and one
/// that grew a line under it would push the rows you are reading. Four figures
/// on one line also ran past the panel and were ellipsized from the right,
/// which cost cache and output — the two a reader cannot infer from the row.
class _MemberDetailLine extends StatelessWidget {
  const _MemberDetailLine({required this.usage, this.loading = false});

  final MemberUsage? usage;

  /// Whether the usage call is still out. The two lines are then bars rather
  /// than words: the hint ("Point at a member…") would be an invitation to hover
  /// for numbers that cannot be shown yet.
  final bool loading;

  /// One line of this block, text or bar. Set explicitly so the skeleton can be
  /// the same height as the sentence it stands in for.
  static const double _fontSize = 11.5;
  static const double _lineHeight = 1.3;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final measured = usage != null;
    // Always two lines, hovered or not. The idle state spends the first saying
    // what to do and leaves the second empty — an empty `Text` still lays out
    // its line box, so the height holds without a hardcoded number that OS text
    // scaling would clip.
    final lines = measured
        ? memberUsageLines(usage!)
        : const ['Point at a member for their 24h split.', ''];
    final style = TextStyle(
      fontSize: _fontSize,
      height: _lineHeight,
      color: measured ? AppPalette.textSecondary : AppPalette.textFaint,
      fontFeatures: AppFont.tabularFigures,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: AppPalette.divider),
          const SizedBox(height: 8),
          if (loading)
            // Two bars of unequal width, exactly as tall as the two lines they
            // become — the block's height is what must not move.
            for (final factor in const [0.72, 0.54])
              SizedBox(
                height: _fontSize * _lineHeight,
                child: Center(
                  child: SkeletonLine(widthFactor: factor, height: 8),
                ),
              )
          else
            for (final line in lines)
              Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
        ],
      ),
    );
  }
}

/// The machines online right now, gathered under the people who run them — the
/// panel behind the pill's node count.
///
/// Strongest first ([gridOnlineNodesProvider]) and named the way the hardware
/// panel names them ([shortenNodeNames]), so the same machine reads the same in
/// both places.
///
/// **A block an owner, not a row a machine.** Four lines each was four lines
/// of which two were shared with the row above: on a grid where one person runs
/// three identical Mac Studios, `@design`, `Apple M2 Ultra · macOS` and
/// `1 chat model` were each printed three times, and the panel spent its width
/// saying the same thing over. [groupNodesByOwner] states the shared half once,
/// at the head of a block, and leaves each row carrying only the name and the
/// speed that tell its machine from its neighbour.
///
/// **The work is counted once a block, and only in words.** "Which of these
/// machines is carrying the grid" is what the list is opened to answer, and it
/// gets answered at the level the list is now organised by — the owner
/// ([groupWorkLabel]). Two attempts to answer it per machine, in ink, are gone:
/// a 3px rule in the rail read as a bullet in front of the name, and a tinted
/// band behind the row read as a row that had been selected. A 332px popover
/// has no room for a measure that argues, and a measure nobody can read is
/// worse than the figure it replaced.
class GridNodesList extends ConsumerWidget {
  const GridNodesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes = ref.watch(gridOnlineNodesProvider);
    final labels = shortenNodeNames([for (final n in nodes) n.name]);
    final groups = groupNodesByOwner(nodes, labels);
    // One scale across the whole panel, not one per block: the meters are read
    // down the list, and a scale that restarted at each owner would draw a
    // laptop as fast as a rack.
    final peak = peakThroughput(nodes);
    return _PanelBody(
      label: 'Nodes',
      trailing: '${nodes.length}',
      emptyText: 'No computer is online on this grid right now.',
      itemCount: groups.length,
      // Taller than the other two panels: its items are blocks, not lines. The
      // cap still bites well before a long grid could outgrow the window — past
      // it the list scrolls, which is the right trade for a panel that hangs
      // over the page it opened from.
      maxHeight: 388,
      itemBuilder: (context, i) => _NodeGroupBlock(
        group: groups[i],
        peak: peak,
        last: i == groups.length - 1,
      ),
    );
  }
}

/// One owner's machines: who they are and what they bring, then a row a
/// machine.
///
/// Recessed rather than divided, because the blocks are what the eye counts
/// first and a rule between them would leave the rows and the headings on one
/// flat plane. [AppCard.inset] inside the panel's own surface is the app's
/// recipe for exactly this — a well inside a card — and it is barely a step
/// (1.09:1 dark, 1.07:1 light) on purpose: the grouping is carried by the tile
/// and the heading above it, and the fill only agrees with them.
class _NodeGroupBlock extends StatelessWidget {
  const _NodeGroupBlock({
    required this.group,
    required this.peak,
    required this.last,
  });

  final NodeGroup group;

  /// The fastest machine on the grid, in tokens a second — every meter's full
  /// length.
  final double peak;

  /// Whether this is the bottom block, which pays no gap under it — the panel
  /// has its own padding, and a block's margin on top of it reads as the list
  /// having stopped short.
  final bool last;

  /// The left column the owner's tile stands in. Its machines are indented past
  /// it, so a name reads as belonging to the handle above it and the block has
  /// one left edge rather than three.
  static const double _rail = _NodeInitial.size;

  /// Between the rail and the text beside it — [_PanelRow]'s own leading gap,
  /// so a node's name starts where a member's does one panel over.
  static const double _gap = 9;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A machine the relay attributed to nobody has no owner to head a block
    // with, and nothing shared to say above its rows. They fall into one
    // headless block whose rows carry their own hardware, rather than into a
    // heading that would have to invent a name for them.
    final headed = group.handle.isNotEmpty;
    final spec = groupSpecLine(group);
    final work = headed ? groupWorkLabel(group) : '';
    final memory = headed ? groupMemoryLabel(group) : '';
    // A one-machine block names its machine in the heading and describes it on
    // the line below; a row under that would print the same name twice.
    final rows = headed && group.isSingle
        ? const <NodeEntry>[]
        : group.machines;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppCard.inset,
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (headed)
                Row(
                  children: [
                    _NodeInitial(email: group.email),
                    const SizedBox(width: _gap),
                    Expanded(
                      child: Text(
                        groupTitle(group),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: AppFont.medium,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                    ),
                    // Both of the block's figures, stacked into one right-hand
                    // column: what it brings, then what it did. They shared the
                    // line below with the hardware description, and on a block
                    // of four Mac Studios the two together ran 280px into a
                    // 246px line — which wrapped `4 × Apple M2 Ultra ·` onto one
                    // row and `macOS` onto the next, breaking the phrase at its
                    // separator. Moved here, the description gets the full width
                    // and the figures get a column that can be read down.
                    if (memory.isNotEmpty || work.isNotEmpty) ...[
                      const SizedBox(width: 9),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (memory.isNotEmpty) _PanelFigure(text: memory),
                          if (work.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(
                                top: memory.isEmpty ? 0 : 3,
                              ),
                              child: _PanelFigure(text: work),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              if (spec.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: headed ? 5 : 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(width: _rail),
                      const SizedBox(width: _gap),
                      Expanded(
                        child: Text(
                          spec,
                          // Two, for the one string here whose length nothing
                          // bounds: a server CPU brand runs half again as long
                          // as any GPU name.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: AppPalette.textFaint,
                          ),
                        ),
                      ),
                      // A one-machine block has no rows, so this line is that
                      // machine's row and ends the way one does.
                      if (group.isSingle)
                        _SpeedColumn(
                          node: group.first,
                          share: speedShare(group.first, peak),
                        ),
                    ],
                  ),
                ),
              for (final entry in rows)
                _MachineRow(
                  entry: entry,
                  spec: entrySpecLine(group, entry.node),
                  share: speedShare(entry.node, peak),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark at the head of a node block — the owner's initial in an accent
/// ring.
///
/// A ring rather than the members panel's filled tile, and the two lists are
/// meant to differ. A roster is a column of people and its tiles are the
/// column's rhythm; a node panel is a column of *machines* whose owners are the
/// dividers between them, and a stack of saturated tiles down that panel pulled
/// the eye onto the handles instead of the hardware they head. Drawn in the
/// accent at its full strength, so the mark still leads the block without
/// filling it.
///
/// **The one deliberate exception to the app's no-borders rule.** §1 of the
/// design system bans a border because a border is how a surface fakes depth,
/// and this is not a surface — it is a glyph, at the same weight the letter
/// inside it is drawn. It carries no lift, and nothing sits on it.
///
/// [AppPalette.accentOnSurface], never [AppPalette.accent]: this is ink on the
/// block's own fill, and `#2F5BEA` on a dark one manages 2.6:1. The variant
/// holds 5.75:1 dark and 5.14:1 light.
///
/// Reads the theme itself: this block is built by a `ListView.builder`, which
/// keeps a child it has already built across the panel's rebuilds, so a watch
/// higher up would never reach it on a theme flip.
class _NodeInitial extends StatelessWidget {
  const _NodeInitial({required this.email});

  final String email;

  /// The width of the block's whole left rail, not just this mark: the work
  /// bars beneath it are drawn to the same figure, and a tile that sized itself
  /// would take the column out of line.
  static const double size = 22;

  /// Heavy enough to read as drawn rather than as an artefact at 22px, light
  /// enough that the ring does not close up around the letter.
  static const double _ring = 1.5;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final color = AppPalette.accentOnSurface;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // The accent at a tenth, so the disc reads as filled rather than as a
        // hole cut in the block — the ring alone left the letter floating on
        // the recess behind it.
        color: AppCard.tint10,
        border: Border.all(color: color, width: _ring),
      ),
      child: Text(
        memberInitial(email),
        // A step down from the members tile's 11.5: the ring eats 3px of the
        // same 22px box, and the glyph has to clear it on both sides.
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// One machine inside a block: its name and how fast it answers.
///
/// [spec] is normally empty: the block above already said what these machines
/// are. It fills only where a block's machines disagree, and then the row has
/// to describe itself.
class _MachineRow extends StatelessWidget {
  const _MachineRow({
    required this.entry,
    required this.spec,
    required this.share,
  });

  final NodeEntry entry;
  final String spec;

  /// This machine's speed against the grid's fastest, 0…1, or null when it
  /// advertised none.
  final double? share;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: _NodeGroupBlock._rail),
          const SizedBox(width: _NodeGroupBlock._gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppPalette.textPrimary,
                  ),
                ),
                if (spec.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      spec,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppPalette.textFaint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _SpeedColumn(node: entry.node, share: share),
        ],
      ),
    );
  }
}

/// A machine's speed, as a meter and the figure it fills to.
///
/// **The meter sits against its own number, in the row's numeric column.** Two
/// earlier attempts put a measure elsewhere and both were misread: a rule in
/// the block's left rail landed where a bullet lands and read as one, and a
/// band behind the whole row landed in the language of hover and read as a
/// selection. Beside the figure it explains, in a column that already means
/// "how much", a bar has nowhere else to be read as.
///
/// Empty — no meter, no figure, no width — when the machine advertised no
/// throughput, so a row for a provider too old to report it keeps its whole
/// line for its name rather than reserving a lane for a blank.
class _SpeedColumn extends StatelessWidget {
  const _SpeedColumn({required this.node, required this.share});

  final OverviewNode node;
  final double? share;

  /// Short, because it is paying for the name beside it. A meter reading
  /// against a figure does not need length to be understood — the number is
  /// right there — only enough to sort fast from slow at a glance.
  static const double _width = 26;

  static const double _height = 4;

  /// The figure's own column, so every meter on the panel starts at the same x.
  ///
  /// Without it the figures set their own widths and each meter floated to
  /// wherever its number left room — `~222 tok/s` pushing its bar ten pixels
  /// left of `~12 tok/s`'s. A column of bars read against each other is the
  /// whole reason to draw bars at all, and bars measured from different
  /// origins cannot be. Wide enough for the longest throughput a node
  /// realistically advertises (`~222 tok/s`); a four-digit one would sit tight
  /// rather than shift the column.
  static const double _figureWidth = 62;

  /// Centres the rule on the 12.5pt line the machine's name occupies.
  static const double _lift = 6;

  /// A machine at 2% of the grid's fastest would otherwise fill half a pixel,
  /// and "slow" would render exactly like "not measured" — which is the
  /// distinction the absent meter above is for.
  static const double _floor = _height;

  /// The band's colour. Measured against the block's fill, the three clear
  /// 4.68:1 at their worst — well past the 3:1 WCAG 1.4.11 asks of a graphic
  /// that carries meaning, which this one does.
  ///
  /// Red is deliberately absent. The scale is speed *against the fastest
  /// machine on this grid*, so its bottom is a laptop keeping up with a rack —
  /// slower, not broken — and [AppPalette.error] in this app is reserved for
  /// something that has actually gone wrong.
  ///
  /// [AppPalette.accentOnSurface], never [AppPalette.accent]: this is ink read
  /// against a background, and `#2F5BEA` on a dark one manages 2.6:1.
  static Color _bandColor(SpeedBand band) => switch (band) {
    SpeedBand.trailing => AppPalette.warn,
    SpeedBand.steady => AppPalette.accentOnSurface,
    SpeedBand.leading => AppPalette.online,
  };

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final figure = entryFigure(node);
    if (figure.isEmpty) return const SizedBox.shrink();
    // The length the bar settles at, floored — computed here rather than inside
    // the tween so the growth runs 0 → floored length. Flooring inside would
    // put the bar at [_floor] on the first frame, which is a bar appearing
    // rather than a bar growing.
    final filled = share == null ? 0.0 : math.max(_floor, _width * share!);
    return Row(
      children: [
        if (share case final value?) ...[
          const SizedBox(width: 9),
          Padding(
            padding: const EdgeInsets.only(top: _lift),
            child: SizedBox(
              width: _width,
              height: _height,
              // Both bars carry their own width *and* height: a `DecoratedBox`
              // with no child collapses to `constraints.smallest` under a
              // `Stack`'s loose fit, which is 0×0 and drew nothing at all.
              child: Stack(
                children: [
                  Container(
                    width: _width,
                    height: _height,
                    decoration: BoxDecoration(
                      // Derived from the faint ink rather than a hairline
                      // token: 8% white on the block's fill measures 1.25:1
                      // against it, a groove nobody would find. This holds
                      // 1.47:1 dark and 1.41:1 light.
                      color: AppPalette.textFaint.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(_height / 2),
                    ),
                  ),
                  // Grows from nothing to its length, and eases between
                  // lengths when a poll moves the figure — the same builder
                  // does both, because it animates whenever `end` changes and
                  // `end` starts at zero.
                  //
                  // The panel is rebuilt by a poll every few seconds, and this
                  // does *not* replay then: the element survives the rebuild,
                  // so a machine holding its speed holds its bar still. It
                  // replays when the panel is opened again, which is the only
                  // time there is anything new to draw.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: filled),
                    duration: AppMotion.meter,
                    curve: AppMotion.curve,
                    builder: (context, width, _) => Container(
                      width: width,
                      height: _height,
                      decoration: BoxDecoration(
                        // The band of the value it is *arriving at*, never of
                        // the width it happens to be passing through. A bar on
                        // its way to green would otherwise be amber for the
                        // first hundred milliseconds and blue for the next —
                        // three claims about one machine, two of them false.
                        color: _bandColor(speedBand(value)),
                        borderRadius: BorderRadius.circular(_height / 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(width: 7),
        SizedBox(
          width: _figureWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: _PanelFigure(text: figure),
          ),
        ),
      ],
    );
  }
}

/// What the grid's tokens were made of — the panel behind the pill's token
/// figure.
///
/// The pill can only carry one number, and the one it carries is output: that is
/// the half where the time goes. The other three live here, one hover away,
/// because they are the context that makes the headline readable — a grid whose
/// input dwarfs its output is being asked long questions, and one whose cache is
/// cold pays full price for every one of them.
///
/// These same four rows also sit in the hardware panel, and that repetition is
/// deliberate: this panel answers "what were those tokens?" without making
/// somebody open the whole hardware breakdown to find out, while the hardware
/// panel keeps them because a reader taking in the grid as a whole should not
/// have to hunt for the work it did.
///
/// **Input is the *fresh* half.** Cached prefill is a share of input, not a
/// fourth kind (see [AnsweredTokens]), so these three rows add up to exactly
/// what the grid handled. Printing `tokensIn` raw would show a panel whose rows
/// sum to more than its own grid did.
class GridTokensList extends ConsumerWidget {
  const GridTokensList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final answered = ref.watch(gridPowerProvider).answered;
    if (answered == null) {
      return const PillPanelMessage(
        text: 'This grid has not reported what it has answered yet.',
      );
    }
    final window = answeredWindowLabel(answered.windowSeconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The span is in the heading rather than repeated on all four rows: it
        // is one fact about the block, and saying it four times would make the
        // rows harder to compare rather than more honest.
        PillPanelLabel(
          label: 'Tokens',
          trailing: window.isEmpty ? null : 'last $window',
        ),
        const SizedBox(height: 10),
        PillPanelStatRow(
          label: 'Input',
          value: formatCount(answered.freshInputTokens),
          unit: 'tokens',
        ),
        // Kept at zero: a grid whose cache never hits should be able to see
        // that, and a row that vanishes at zero makes the rest look like the
        // whole story.
        PillPanelStatRow(
          label: 'Cached',
          value: formatCount(answered.tokensCached),
          unit: 'tokens',
        ),
        PillPanelStatRow(
          label: 'Output',
          value: formatCount(answered.tokensOut),
          unit: 'tokens',
        ),
        PillPanelStatRow(
          label: 'Answered',
          value: formatCount(answered.requests),
          unit: plural(answered.requests, 'request'),
        ),
      ],
    );
  }
}

/// A panel's heading over its rows, or a line of prose when there are none.
///
/// The list is lazy and capped: a grid can have a hundred members, and the rows
/// past the fold cost nothing to leave unbuilt. The cap keeps a long list from
/// growing a popover taller than the window.
class _PanelBody extends StatelessWidget {
  const _PanelBody({
    required this.label,
    required this.trailing,
    required this.emptyText,
    required this.itemCount,
    required this.itemBuilder,
    this.maxHeight = 272,
  });

  final String label;

  /// The section's own figure, on the right of its heading. Null omits it —
  /// which is a list whose total is not known yet, never one whose total is
  /// zero.
  final String? trailing;

  final String emptyText;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// How tall the list may grow before it scrolls — enough rows to read at a
  /// glance, never enough to outgrow the window.
  final double maxHeight;

  /// The lane the scroll thumb runs down, kept clear of the rows.
  ///
  /// The thumb is drawn over the viewport, not beside it, so without this it
  /// lands on top of the one column it is guaranteed to cover: the right-hand
  /// one every row ends with — a member's "Work email", a machine's memory. Its
  /// own 6px (`scrollbarTheme`) and a little air, so a long row runs *behind*
  /// the thumb rather than under it. The heading pays the same inset, so the
  /// section's count stays in line with the column beneath it whether or not
  /// there is enough list to scroll.
  static const double _thumbLane = 11;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: _thumbLane),
          child: PillPanelLabel(label: label, trailing: trailing),
        ),
        const SizedBox(height: 10),
        if (itemCount == 0)
          Text(
            emptyText,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: AppPalette.textSecondary,
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.builder(
              padding: const EdgeInsets.only(right: _thumbLane),
              shrinkWrap: true,
              itemCount: itemCount,
              itemBuilder: itemBuilder,
            ),
          ),
      ],
    );
  }
}

/// One row: the name, and what there is to say about it on the right.
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.label,
    this.labelSuffix,
    this.leading,
    this.trailing,
    this.badge,
    this.strong = false,
  });

  final String label;

  /// Carried straight on from [label], in the faint ink — a member's row prints
  /// `dev` and then `@autonomous.ai`, which reads as one address with the half
  /// that differs in front.
  ///
  /// One text span rather than two widgets, so the ellipsis falls at the end of
  /// the pair: a row too narrow for the whole address loses the tail of the
  /// domain, which every row on a work grid repeats, instead of the name, which
  /// is the only thing the row is read for.
  final String? labelSuffix;

  /// A mark in front of the label — the members list's initial tile. Null on
  /// every other panel: a node's row is already four lines and a model id is a
  /// string, not a person.
  final Widget? leading;

  /// Whether the label is the row's subject rather than one of its facts.
  ///
  /// A member's handle is what the whole row is about and carries a coloured
  /// mark beside it; at regular weight the two read as unrelated. A machine name
  /// or a model id sits above its own detail lines and needs no such lift.
  final bool strong;

  /// The right-hand column: a figure ([_PanelFigure]), or its skeleton while the
  /// call that produces it is still out.
  ///
  /// A widget rather than a string, so "the number isn't here yet" and "there is
  /// no number" can look different. They are different facts — a member with no
  /// figure has run nothing, a member whose figure is still loading may have run
  /// the most on the grid — and a `String?` could only ever say the second.
  final Widget? trailing;

  /// A chip between the label and the figure — what this row *is*, where the
  /// two sides say what it is called and what it holds.
  ///
  /// Between them rather than at the end because the end is a numeric column: a
  /// word landing there would break the alignment the figures are read down, and
  /// on the one row that carried it. The label keeps its `Expanded`, so a long
  /// address ellipsizes into the chip rather than pushing it off the row.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (leading case final mark?) ...[mark, const SizedBox(width: 9)],
          Expanded(
            child: Text.rich(
              TextSpan(
                text: label,
                children: [
                  if (labelSuffix case final suffix?)
                    TextSpan(
                      text: suffix,
                      // Regular weight as well as the faint ink: the domain is
                      // the part every row agrees on, and repeating the label's
                      // medium down the column would make the thing to skip as
                      // heavy as the thing to read.
                      style: TextStyle(
                        fontWeight: FontWeight.w400,
                        color: AppPalette.textFaint,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppFont.sans,
                fontFamilyFallback: AppFont.sansFallback,
                fontSize: 13,
                fontWeight: strong ? AppFont.medium : null,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          if (badge case final text?) ...[
            const SizedBox(width: 9),
            PillPanelBadge(label: text),
          ],
          if (trailing case final figure?) ...[
            const SizedBox(width: 9),
            figure,
          ],
        ],
      ),
    );
    return row;
  }
}

/// A row's right-hand figure — what it holds, where the label says what it is.
///
/// Its own widget because the skeleton that stands in for it has to match its
/// metrics exactly, and a style written inline in [_PanelRow] gave the skeleton
/// nothing to measure itself against.
class _PanelFigure extends StatelessWidget {
  const _PanelFigure({required this.text});

  final String text;

  /// The type this figure is set in. Shared with [_FigureSkeleton] so the bar
  /// and the number it becomes occupy the same line box.
  static const double fontSize = 11.5;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        color: AppPalette.textFaint,
        // These refresh in place when a poll lands, and digits of differing
        // width make the column twitch.
        fontFeatures: AppFont.tabularFigures,
      ),
    );
  }
}

/// The bar standing in for a figure whose request is still out.
///
/// Sized to the figure it replaces rather than to the skeleton default: this
/// column sits at the end of a row that is already on screen, so a bar of the
/// wrong height would shift the row when the number lands — the one thing a
/// skeleton exists to prevent.
class _FigureSkeleton extends StatelessWidget {
  const _FigureSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: _PanelFigure.fontSize * 1.3,
      width: 38,
      child: Center(child: Skeleton.text(height: 8)),
    );
  }
}
