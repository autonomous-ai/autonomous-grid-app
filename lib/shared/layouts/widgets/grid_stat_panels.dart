import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/member_usage_provider.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredSummary, answeredWindowLabel, formatCount;
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/api/models/member_usage.dart';
import '../../theme/app_theme.dart';
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
  static const double defaultWidth = 276;

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
            child: PillPanelSurface(child: child),
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

/// Who is on this grid, by email, busiest reader first — the panel behind the
/// pill's member count.
///
/// Two sources, joined here: the roster comes from the control plane (everyone
/// who *may* use the grid) and the usage from the relay (what each of them
/// actually ran in the last 24h). Neither knows the other, so a member who has
/// never sent a request appears with no figure and a consumer the roster has
/// since dropped simply doesn't appear — the roster decides who is listed.
class GridMembersList extends ConsumerStatefulWidget {
  const GridMembersList({super.key});

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
    // Read for its *value*, never its loading state: the roster is what the
    // panel is for, and blocking the whole list on a second request would make
    // an already-known roster arrive late. Absent usage degrades to an
    // unranked, unlabelled list rather than to a spinner.
    final usage = ref.watch(gridMemberUsageProvider).value;
    return ref
        .watch(networkMembersProvider(grid.networkId))
        .when(
          loading: () => const _PanelMessage(text: 'Loading members…'),
          // The provider's own message, which is already written for a person
          // ("Sign in to manage members.") rather than a socket error.
          error: (err, _) => _PanelMessage(text: '$err'),
          data: (members) {
            final byEmail = usage?.byEmail;
            final rows = sortMembersByUsage(
              members,
              byEmail,
              emailOf: (m) => m.email,
            );
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
                    isOwner: rows[i].isOwner,
                    usage: memberUsageFor(byEmail, rows[i].email),
                    hovered: _hovered == rows[i].email,
                    onHover: (over) => _onHover(rows[i].email, over),
                  ),
                ),
                // Only where there is something to point at. A grid with no
                // usage would otherwise carry a permanent line inviting a hover
                // that can never say anything.
                if (byEmail != null && rows.isNotEmpty)
                  _MemberDetailLine(usage: hovered),
              ],
            );
          },
        );
  }
}

/// One member: the address, their 24h input figure, and the full split on hover.
///
/// Input leads because reading is what a grid is asked to do — output follows
/// from it, and requests count turns rather than work. The other three are a
/// hover away rather than on the row: four numbers per line in a 300px panel
/// would leave no room for the address, which is the thing being looked up.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.email,
    required this.isOwner,
    required this.usage,
    required this.hovered,
    required this.onHover,
  });

  final String email;
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

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = _PanelRow(
      label: email,
      badge: isOwner ? 'owner' : null,
      // The **fresh** input leg, matching the hover's "input tokens" line and the
      // pill's own figure. Printing `tokensIn` raw here made the row larger than
      // the number the tooltip called input, which reads as a bug rather than as
      // the cache being a share of it.
      trailing: usage == null ? null : formatCount(usage!.freshInputTokens),
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
  const _MemberDetailLine({required this.usage});

  final MemberUsage? usage;

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
      fontSize: 10.5,
      color: measured ? AppPalette.textSecondary : AppPalette.textFaint,
      fontFeatures: AppFont.tabularFigures,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: AppPalette.divider),
          const SizedBox(height: 7),
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

/// The machines online right now — the panel behind the pill's node count.
///
/// Strongest first ([gridOnlineNodesProvider]) and named the way the hardware
/// panel names them ([shortenNodeNames]), so the same machine reads the same in
/// both places.
///
/// Three lines a machine, because a name and a memory figure don't answer what
/// people actually ask of this list: which box is which ("M3 Ultra"), what it
/// serves (chat or images), and whether it is busy. The last line is live
/// telemetry and is routinely short or absent — see [nodeActivityLine].
class GridNodesList extends ConsumerWidget {
  const GridNodesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes = ref.watch(gridOnlineNodesProvider);
    final labels = shortenNodeNames([for (final n in nodes) n.name]);
    return _PanelBody(
      label: 'Nodes',
      trailing: '${nodes.length}',
      emptyText: 'No computer is online on this grid right now.',
      itemCount: nodes.length,
      // Taller than the other two panels: its rows are four lines, not one. The
      // cap still bites well before a long grid could outgrow the window — past
      // it the list scrolls, which is the right trade for a panel that hangs
      // over the page it opened from.
      maxHeight: 360,
      itemBuilder: (context, i) => _NodeRow(name: labels[i], node: nodes[i]),
    );
  }
}

/// One machine: its name and memory, what it is, and what it's doing.
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.name, required this.node});

  final String name;
  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final machine = nodeMachineLine(node);
    final serving = nodeServingLine(node);
    final activity = nodeActivityLine(node);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // What it's called, what it is, what it offers, what it has done — in
          // that order, because that is the order the questions get asked. Each
          // on its own line: the machine name is the one string here whose
          // length nothing bounds, and every fact sharing its line was a fact
          // that disappeared when a box turned out to be an EPYC.
          // The owner's handle before the machine's name: on a shared grid the
          // first question a row answers is whose box this is, and a hostname
          // rarely says. Dropped when the relay named nobody, so the row falls
          // back to the name alone rather than leading with an empty marker.
          _PanelRow(
            label: switch (nodeHostHandle(node)) {
              '' => name,
              final handle => '$handle · $name',
            },
            trailing: _nodeDetail(node),
            dense: true,
          ),
          if (machine.isNotEmpty)
            _NodeDetailLine(text: machine, live: false, maxLines: 2),
          if (serving.isNotEmpty) _NodeDetailLine(text: serving, live: false),
          if (activity.isNotEmpty) _NodeDetailLine(text: activity, live: true),
        ],
      ),
    );
  }
}

/// A machine's second or third line. The live one ([live]) sits a step brighter
/// than the static spec above it, and in tabular figures — it is the line whose
/// numbers move, and digits of differing width would make the row twitch on
/// every refresh.
class _NodeDetailLine extends StatelessWidget {
  const _NodeDetailLine({
    required this.text,
    required this.live,
    this.maxLines = 1,
  });

  final String text;
  final bool live;

  /// How far this line may wrap before it ellipsizes.
  ///
  /// Two for the machine line, one for the live one. The machine line's length
  /// is set by strings the app doesn't control — a server CPU brand runs half
  /// again as long as any GPU name, even after the boilerplate is stripped — and
  /// what gets cut there is the tail, where the model count lives. The live line
  /// is figures the app formats itself, so it is bounded by construction and a
  /// second row would only ever be empty space.
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          color: live ? AppPalette.textSecondary : AppPalette.textFaint,
          fontFeatures: live ? AppFont.tabularFigures : null,
        ),
      ),
    );
  }
}

/// What a node brings, in the order that says most about it: the memory it puts
/// into the pool, else its subscription tier, else whatever spec it reports.
/// Null when it reports nothing — the row is then the machine's name alone,
/// which is honest, where a placeholder would not be.
///
/// Through [nodeVramGb] and [nodeMemoryKind], the same pair the hardware panel
/// uses, so a machine reads identically in both: a codex seat falls to its plan
/// rather than advertising RAM that runs no model for the grid, and Apple
/// Silicon's unified memory is called RAM in both places.
String? _nodeDetail(OverviewNode node) {
  final gb = nodeVramGb(node);
  if (gb != null) return '${formatVram(gb)} ${nodeMemoryKind(node)}';
  final plan = nodePlanLabel(node);
  if (plan != null) return plan;
  final spec = nodeSpecLine(node);
  return spec.isEmpty ? null : spec;
}

/// The models this grid can answer with — the panel behind the pill's model
/// count. Ids in mono, like every other place the app shows one: a model id gets
/// pasted into a config, so `l`/`1` and `0`/`O` have to stay apart.
class GridModelsList extends ConsumerWidget {
  const GridModelsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(gridModelsProvider);
    // Summed across the machines serving each model: the relay reports the
    // rollup per node, so the grid-level figure for a model exists nowhere in
    // the payload and is added up here.
    final answered = answeredByModel(ref.watch(gridOnlineNodesProvider));
    // The grid-level rollup, used only to tell "served nothing today" from
    // "nothing measured it" for a model the map has no rows for — see
    // [modelAnswered].
    final gridTotal = ref.watch(gridPowerProvider).answered;
    return _PanelBody(
      label: 'Models',
      trailing: '${models.length}',
      emptyText: 'This grid serves no model yet.',
      itemCount: models.length,
      // Taller than the models list used to be: every row is two lines now that
      // an unused model states its zero instead of going quiet.
      maxHeight: 320,
      itemBuilder: (context, i) => _ModelRow(
        model: models[i],
        answered: modelAnswered(answered, models[i].id, gridTotal: gridTotal),
      ),
    );
  }
}

/// One model: its id, and what the grid answered with it.
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.answered});

  final OverviewModel model;

  /// Null when no relay measured this model — the second line is then omitted
  /// rather than printed as zeros, which would claim the grid has a model
  /// nobody uses. A model that was measured and answered nothing does get its
  /// `0 tokens`, which is a different and true statement.
  final NodeAnswered? answered;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final summary = answeredSummary(answered);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelRow(
            label: model.id,
            mono: true,
            // Only media capabilities are named: labelling every text model
            // "Chat" would paint one word down the whole column and say nothing.
            trailing: mediaCapabilityLabel(model.id),
            dense: true,
          ),
          if (summary.isNotEmpty) _NodeDetailLine(text: summary, live: true),
        ],
      ),
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
      return const _PanelMessage(
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
        const SizedBox(height: 9),
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
    this.maxHeight = 252,
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
  static const double _thumbLane = 10;

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
        const SizedBox(height: 9),
        if (itemCount == 0)
          Text(
            emptyText,
            style: TextStyle(
              fontSize: 12,
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
    this.trailing,
    this.badge,
    this.mono = false,
    this.dense = false,
  });

  final String label;
  final String? trailing;

  /// A chip between the label and the figure — what this row *is*, where the
  /// two sides say what it is called and what it holds.
  ///
  /// Between them rather than at the end because the end is a numeric column: a
  /// word landing there would break the alignment the figures are read down, and
  /// on the one row that carried it. The label keeps its `Expanded`, so a long
  /// address ellipsizes into the chip rather than pushing it off the row.
  final String? badge;

  /// Whether [label] is a string people copy (a model id) rather than read.
  final bool mono;

  /// Drops the row's own vertical breathing room — for a caller that is itself
  /// a multi-line block ([_NodeRow]) and spaces its lines as a whole.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 0 : 3.5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: mono ? AppFont.mono : AppFont.sans,
                fontFamilyFallback: mono
                    ? AppFont.monoFallback
                    : AppFont.sansFallback,
                fontSize: 12,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          if (badge case final text?) ...[
            const SizedBox(width: 8),
            PillPanelBadge(label: text),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: AppPalette.textFaint,
                fontFeatures: AppFont.tabularFigures,
              ),
            ),
          ],
        ],
      ),
    );
    return row;
  }
}

/// The panel while its list is loading, or when it can't be read at all.
class _PanelMessage extends StatelessWidget {
  const _PanelMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.35,
        color: AppPalette.textSecondary,
      ),
    );
  }
}
