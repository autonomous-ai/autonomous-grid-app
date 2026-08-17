import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredSummary, answeredWindowLabel, formatCount;
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';
import 'pill_panel_shell.dart';

/// The panel behind one figure in the top bar's grid pill: hovering "18 members"
/// names the eighteen, "8 nodes" the eight machines, "7 models" the seven models.
///
/// The pill's numbers used to be unreadable in the only way that matters — you
/// could see *how many* and never *which*, and the one panel the pill opened
/// answered that for the machines alone. A count is a question; this is where it
/// gets its answer, without leaving the screen you're on.
///
/// The frame only: anchored under its own figure (not the whole pill, so it
/// points at the number it belongs to) and carrying the shared surface. What
/// goes inside is [GridMembersList] / [GridNodesList] / [GridModelsList].
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

/// Who is on this grid, by email — the panel behind the pill's member count.
class GridMembersList extends ConsumerWidget {
  const GridMembersList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(selectedNetworkProvider);
    if (grid == null) return const SizedBox.shrink();
    return ref
        .watch(networkMembersProvider(grid.networkId))
        .when(
          loading: () => const _PanelMessage(text: 'Loading members…'),
          // The provider's own message, which is already written for a person
          // ("Sign in to manage members.") rather than a socket error.
          error: (err, _) => _PanelMessage(text: '$err'),
          data: (members) => _PanelBody(
            label: 'Members',
            trailing: '${members.length}',
            emptyText: 'No one is on this grid yet.',
            itemCount: members.length,
            itemBuilder: (context, i) => _PanelRow(
              label: members[i].email,
              // Owner first, because it outranks the other note; a work-email
              // member is marked so the roster explains itself here the same way
              // the Members tab does.
              trailing: members[i].isOwner
                  ? 'Owner'
                  : members[i].isDomainMember
                  ? 'Work email'
                  : null,
            ),
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
          _PanelRow(label: name, trailing: _nodeDetail(node), dense: true),
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
    return _PanelBody(
      label: 'Models',
      trailing: '${models.length}',
      emptyText: 'This grid serves no model yet.',
      itemCount: models.length,
      // Taller than the members panel: its rows are two lines, not one.
      maxHeight: 300,
      itemBuilder: (context, i) => _ModelRow(
        model: models[i],
        answered: answered[modelKey(models[i].id)],
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
  final String trailing;
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
    this.mono = false,
    this.dense = false,
  });

  final String label;
  final String? trailing;

  /// Whether [label] is a string people copy (a model id) rather than read.
  final bool mono;

  /// Drops the row's own vertical breathing room — for a caller that is itself
  /// a multi-line block ([_NodeRow]) and spaces its lines as a whole.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
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
