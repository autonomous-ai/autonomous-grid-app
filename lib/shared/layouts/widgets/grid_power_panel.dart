import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../features/network/presentation/node_dashboard_dialog.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import 'grid_stat_panels.dart';
import 'memory_split_bar.dart';
import 'pill_panel_shell.dart';

/// The panel behind the top bar's grid pill: the grid's hardware, the machines
/// providing it, and the way to put this computer among them.
///
/// Anchored to the pill and pushed left so it hangs under the pill's right edge
/// rather than running off the window. Its own file because the pill and the
/// panel are two screens' worth of widget in one bar — [GridPowerPill] is the
/// capsule and its states, this is everything that opens out of it.
class GridPowerPanel extends ConsumerWidget {
  const GridPowerPanel({
    super.key,
    required this.link,
    required this.anchorKey,
    required this.gridName,
    required this.tapGroupId,
    required this.onEnter,
    required this.onExit,
    required this.onDismiss,
  });

  /// The stretch of the capsule this panel was opened from — the grid's name at
  /// one end, the memory ring at the other. Not the capsule as a whole: it runs
  /// ~400px wide, so a panel pinned to one end of it opens a long way from
  /// wherever the pointer actually is. Hovering the name and having the panel
  /// appear under the ring reads as the wrong panel opening.
  final LayerLink link;

  /// The same stretch, as something measurable — [GridStatPanel] needs it to
  /// work out whether the panel still fits on screen where that stretch puts it.
  final GlobalKey anchorKey;

  final String gridName;

  /// Shared with the pill, so a click on either counts as inside — the panel
  /// lives in an overlay, and without this every press on its own button would
  /// read as a tap outside and dismiss it before the press landed.
  final Object tapGroupId;

  final VoidCallback onEnter;
  final VoidCallback onExit;

  /// Closes the panel — for an action that navigates out from under it, which
  /// would otherwise leave the panel hanging over the screen it opened.
  final VoidCallback onDismiss;

  // Wide enough that a node's memory figure ("191.9 GB VRAM") fits its column
  // without eating the machine name beside it.
  static const double _width = 312;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final power = ref.watch(gridPowerProvider);
    final nodes = ref.watch(gridOnlineNodesProvider);
    // One figure, not the whole snapshot: the panel refetches the moment it
    // opens, and this line repaints only if the uptime itself moved. Through
    // [gridOverviewSnapshot] so a poll in flight can't blank it — see there.
    final uptime = ref.watch(
      gridOverviewSnapshot.select((o) => o?.stats.uptimePct),
    );

    final vram = power.vramGb;
    // Absent on a relay that reports no `vram_used_mb` anywhere — the panel then
    // shows what it always did, rather than a bar drawn at zero.
    final used = power.vramUsedGb;
    // Two kinds of machine, shown as two labelled sections instead of one mixed
    // list: hardware nodes that bring GPU memory ("Local models"), and codex
    // subscription seats that bring a plan + usage ("Codex subscription"). The
    // split is `nodeIsSubscription` — the same predicate the VRAM pool uses, so a
    // seat never lands in the memory bar and a GPU never lands under a plan.
    final localNodes = [
      for (final n in nodes)
        if (!nodeIsSubscription(n)) n,
    ];
    final subNodes = [
      for (final n in nodes)
        if (nodeIsSubscription(n)) n,
    ];
    final slices = vram == null
        ? const <NodeSlice>[]
        : buildMemorySlices(localNodes, vram);

    // Placed by [GridStatPanel] like every other panel this pill opens: under
    // the stretch it belongs to, sliding sideways only when the window's edge
    // would otherwise cut it off.
    return GridStatPanel(
      link: link,
      anchorKey: anchorKey,
      tapGroupId: tapGroupId,
      onEnter: onEnter,
      onExit: onExit,
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _PanelHeader(name: gridName, uptimePct: uptime),
          // LOCAL MODELS — hardware nodes: the GPU-memory bar (when any
          // node reports VRAM) above one row per machine.
          if (localNodes.isNotEmpty) ...[
            // IN USE — the figure the pill's ring draws, spelled out. Its own
            // bar rather than a marker on the split below, because the two
            // answer different questions: this one is "how much of the grid is
            // spoken for", that one is "whose memory is it". One bar carrying
            // both had to be read twice to answer either.
            if (vram != null && used != null) ...[
              const SizedBox(height: 12),
              PillPanelLabel(
                label: 'In use',
                trailing:
                    '${formatVramShare(used, vram)} · '
                    '${(used / vram * 100).round()}%',
              ),
              const SizedBox(height: 9),
              _PoolUsageBar(fraction: used / vram),
            ],
            const SizedBox(height: 12),
            PillPanelLabel(
              label: 'Self-host',
              trailing: vram != null ? formatVram(vram) : null,
            ),
            if (slices.isNotEmpty) ...[
              const SizedBox(height: 9),
              MemorySplitBar(slices: slices),
            ],
            const SizedBox(height: 10),
            _NodeBreakdown(nodes: localNodes, totalGb: vram),
          ],
          // CODEX SUBSCRIPTION — seat nodes: name + used% + plan badge,
          // each click-expandable to its usage bars.
          if (subNodes.isNotEmpty) ...[
            const SizedBox(height: 13),
            const PillPanelLabel(label: 'Codex subscription'),
            const SizedBox(height: 8),
            _NodeBreakdown(nodes: subNodes, totalGb: null),
          ],
          _PanelActions(onDismiss: onDismiss),
        ],
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.name, required this.uptimePct});

  final String name;
  final double? uptimePct;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        if (uptimePct != null) ...[
          const SizedBox(width: 8),
          StatusDot(color: AppPalette.online, size: 6),
          const SizedBox(width: 5),
          Text(
            '${_trimPct(uptimePct!)}% uptime',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: AppFont.medium,
              color: AppPalette.online,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
        ],
      ],
    );
  }
}

String _trimPct(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.slice,
    required this.totalGb,
    required this.usedGb,
    required this.memoryKind,
  });

  final NodeSlice slice;
  final double totalGb;

  /// This machine's own memory in use, or null when it doesn't report any.
  ///
  /// Null is not zero, and is not drawn as a full row either: the figure falls
  /// back to the capacity this machine brings and the percentage to an em dash.
  /// A machine that cannot say how much it is using must not be shown as idle
  /// beside one that measured itself.
  final double? usedGb;

  /// "VRAM" for a discrete GPU, "RAM" for Apple Silicon's unified memory — this
  /// node's own kind, so the figure reads "48 GB VRAM" / "32 GB RAM".
  final String memoryKind;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final used = usedGb;
    // The share of *this machine's own* memory when it reported one — what the
    // reader wants once the bar above has said the grid is 64% full. Its share
    // of the pool is already drawn: it is the width of this row's slice in the
    // bar.
    // Clamped, like the pool figure in [GridPower.vramUsedGb]: a node reporting
    // more used than it advertises as total — a driver rounding, a card counted
    // twice — would otherwise print "104%", which reads as a bug in the app
    // rather than as a machine at capacity.
    final pct = used == null
        ? null
        : (used / slice.gb * 100).round().clamp(0, 100);
    final hot = pct != null && pct >= 90;
    return Row(
      children: [
        // A vertical tick, not a dot: it echoes the shape of the slice it names
        // up in the bar, so the eye pairs colour to row without hunting. A
        // round swatch reads as a bullet and loses that link.
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: slice.color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            slice.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppPalette.textPrimary),
          ),
        ),
        const SizedBox(width: 8),
        // Fixed width and right-aligned: tabular figures keep each digit the same
        // width, but "48 GB VRAM" and "32 GB RAM" are different lengths, so
        // without a column the values step raggedly down the panel.
        SizedBox(
          // 112, not the 100 a lone capacity needed: the row now carries a
          // share *and* its kind — "277 / 382 GB VRAM" — and the widest honest
          // case ("1023 / 1024 GB VRAM") has to fit without eating into the
          // machine name beside it.
          width: 112,
          child: Text(
            used == null
                ? '${formatVram(slice.gb)} $memoryKind'
                : '${formatVramShare(used, slice.gb)} $memoryKind',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
        ),
        const SizedBox(width: 7),
        SizedBox(
          // Wide enough for "100%" so it never wraps to a second line; softWrap
          // off + single line keeps it on the row even if a locale widens it.
          width: 36,
          child: Text(
            pct == null ? '—' : '$pct%',
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 10.5,
              // Amber, and heavier, from the point where this machine has no
              // room left for another model — the one row worth finding
              // without reading the others.
              fontWeight: hot ? AppFont.medium : FontWeight.w500,
              // Not [AppPalette.textFaint], which this column used to take: at
              // 10.5px on the menu fill it measures 2.80:1 dark / 3.33:1 light,
              // under the 4.5:1 small text has to clear. Secondary lands at
              // 6.01:1 / 6.21:1 and still reads as the quietest column in the
              // row.
              color: hot ? AppPalette.warn : AppPalette.textSecondary,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}

/// What to do about any of this — the panel's foot.
///
/// The panel used to end in a lone "View dashboard" link, deliberately quiet so
/// nothing in a hover popup read as the main thing to do. That was the right
/// call for a panel that only reported; it is the wrong one now, because the
/// figures above are exactly where a user asks "can I add to this?" and the
/// screen that answers had no visible door anywhere in the app.
///
/// It reported for a while, then offered, and now reports again — but for a
/// different reason than the first time. The offer was right while the engines screen
/// had no visible door; it has one now, permanently, on the top bar. Keeping a
/// button here as well would mean one screen reached by two controls whose
/// labels disagreed — this one renamed itself between "Run a model here" and
/// "Model engines" depending on whether the machine was serving, which is
/// exactly the confusion the bar's single door removes.
class _PanelActions extends ConsumerWidget {
  const _PanelActions({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Act first, dismiss second: the closure runs from inside the panel, and
    // dismissing it unmounts the widget whose `context` the action still needs.
    // The dialog is already pushed by the time the panel goes.
    return _PanelLink(
      label: 'View dashboard',
      onTap: () {
        showNodeDashboard(context);
        onDismiss();
      },
    );
  }
}

/// A quiet accent text row at the foot of the panel — the shape both of its
/// secondary ways out share, so they can sit side by side without one of them
/// looking heavier than the other.
class _PanelLink extends StatelessWidget {
  const _PanelLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppPalette.accentOnSurface,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                Icons.arrow_forward_rounded,
                size: 12,
                color: AppPalette.accentOnSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every online machine as one row, each carrying its *own* metric: a hardware
/// node its GPU-memory share (coloured to match its slice up in the bar), a
/// subscription seat its plan, and a VRAM-less hardware node whatever spec it
/// reports. One list, not a section per kind — the figure belongs on the node,
/// so "which machine, and what does it bring?" is read down a single column.
/// How much of the pool is in use, as one bar.
///
/// Same colours and the same 85% threshold as the ring in the top bar, so the
/// capsule and the panel behind it never disagree about whether a grid is
/// comfortable — a ring gone amber above a green bar would read as two
/// different measurements of one thing.
class _PoolUsageBar extends StatelessWidget {
  const _PoolUsageBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final value = fraction.clamp(0.0, 1.0);
    final instant = MediaQuery.of(context).disableAnimations;
    // No [Align] around the fill, and none around the track either: Align hands
    // its child *loose* constraints, so the height stops being tight, and a
    // ColoredBox with no child of its own takes the smallest size it is
    // offered — zero. The bar then renders as an empty groove, which is exactly
    // what shipped: full-width track, no fill, whatever the figure said. Same
    // trap [MemorySplitBar] documents on its own slices, and it is invisible to
    // a widget test that only checks the fill exists.
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: ColoredBox(
          color: AppPalette.guide,
          // Filling to the figure rather than appearing at it — the same
          // motion the node panel's speed bars use, and for the same reason:
          // this is a value being drawn, and the reader is meant to watch it
          // arrive. Animating the *factor*, so a window resized mid-fill keeps
          // the bar honest.
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: value),
            duration: instant ? Duration.zero : AppMotion.meter,
            curve: AppMotion.curve,
            builder: (context, filled, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: filled,
              child: ColoredBox(
                color: value >= 0.85 ? AppPalette.warn : AppPalette.online,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NodeBreakdown extends StatelessWidget {
  const _NodeBreakdown({required this.nodes, required this.totalGb});

  final List<OverviewNode> nodes;

  /// The grid's total GPU memory, to turn a node's VRAM into its share. Null
  /// when no node reports any — then every row falls to its plan or spec.
  final double? totalGb;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final labels = shortenNodeNames([for (final n in nodes) n.name]);
    final total = totalGb;
    // Each row with the figure it is ordered by. Built in the nodes' own order —
    // the capacity order the bar is laid out in — and sorted only at the end, so
    // a row's colour still comes from where its slice sits up in the bar rather
    // than from where the row lands in the list.
    final rows = <({double sortKey, int order, Widget row})>[];
    // Only VRAM nodes take a bar colour, and they sort first, so a counter that
    // advances only on them keeps each row's tick matched to its slice.
    var vramIndex = 0;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final gb = nodeVramGb(node);
      // How full this machine is, 0–1. Machines that cannot say sort last: an
      // unknown is not a zero, but it is also not a reading to rank, and the
      // list is ordered to put the machines running out of room on top.
      var sortKey = -1.0;
      Widget row;
      if (gb != null && total != null && total > 0) {
        final used = nodeVramUsedGb(node);
        if (used != null && gb > 0) sortKey = (used / gb).clamp(0.0, 1.0);
        row = _LegendRow(
          slice: NodeSlice(
            label: labels[i],
            gb: gb,
            fraction: gb / total,
            color: sliceColor(vramIndex),
          ),
          totalGb: total,
          usedGb: used,
          memoryKind: nodeMemoryKind(node),
        );
        vramIndex++;
      } else if (nodePlanLabel(node) case final plan?) {
        // A codex seat shows its primary used-% between the name and the plan
        // badge, so the headline "how much have I burned" reads without opening
        // the usage disclosure below. Non-codex plan rows keep just the badge.
        final usedPct = node.engine == 'codex'
            ? node.codexRateLimits?.primary?.usedPercent
            : null;
        row = _NodeRow(
          label: labels[i],
          trailing: usedPct == null
              ? PillPanelBadge(label: plan)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$usedPct%',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: AppPalette.textFaint,
                        fontFeatures: AppFont.tabularFigures,
                      ),
                    ),
                    const SizedBox(width: 8),
                    PillPanelBadge(label: plan),
                  ],
                ),
        );
      } else if (nodeSpecLine(node) case final spec when spec.isNotEmpty) {
        row = _NodeRow(
          label: labels[i],
          trailing: Text(
            spec,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: AppPalette.textFaint,
            ),
          ),
        );
      } else {
        row = _NodeRow(label: labels[i], trailing: const SizedBox.shrink());
      }
      // A codex seat carries a rate-limit snapshot — click the row to disclose its
      // usage bars below (the row stays a clean name+plan line otherwise). Only for
      // codex nodes that actually reported a window.
      if (node.engine == 'codex' && node.codexRateLimits?.primary != null) {
        row = _CodexUsageDisclosure(rates: node.codexRateLimits!, child: row);
      }
      rows.add((
        sortKey: sortKey,
        order: i,
        row: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: row,
        ),
      ));
    }
    // Fullest first, ties broken by the order they came in — which is capacity
    // order, so two machines at the same share still read biggest-first, and the
    // ones reporting nothing keep that order at the bottom.
    //
    // The tie-break is doing real work: `List.sort` is not stable (quicksort
    // above 32 elements), and a grid of identical machines all at the same
    // percentage would otherwise shuffle its own rows on every poll.
    final ordered = [...rows]
      ..sort((a, b) {
        final byShare = b.sortKey.compareTo(a.sortKey);
        return byShare != 0 ? byShare : a.order.compareTo(b.order);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [for (final entry in ordered) entry.row],
    );
  }
}

/// A node row without a memory share — a subscription seat (plan badge) or a
/// VRAM-less machine (spec). A neutral tick keeps its name aligned with the
/// coloured memory rows above without implying a slice of the bar it isn't in.
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.label, required this.trailing});

  final String label;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: AppPalette.textFaint,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppPalette.textPrimary),
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}

/// Click-to-open usage disclosure for a codex seat: tapping the node row toggles
/// a panel below it showing each rate-limit window as a labelled progress bar
/// (used %, and when it resets). Click rather than hover — the panel it sits in
/// is itself a hover popup, so a nested hover would be fiddly. Only mounted for
/// `engine == 'codex'` nodes that reported at least a primary window.
class _CodexUsageDisclosure extends StatefulWidget {
  const _CodexUsageDisclosure({required this.rates, required this.child});

  final CodexRateLimits rates;
  final Widget child;

  @override
  State<_CodexUsageDisclosure> createState() => _CodexUsageDisclosureState();
}

class _CodexUsageDisclosureState extends State<_CodexUsageDisclosure> {
  bool _open = false;

  static bool _hasPeriod(CodexWindow? w) =>
      w != null && w.usedPercent != null && (w.windowMinutes ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Every window the seat reported, primary first — a bar each. A window with
    // no real period (free seats leave `secondary` at 0) is dropped.
    final windows = <CodexWindow>[
      if (_hasPeriod(widget.rates.primary)) widget.rates.primary!,
      if (_hasPeriod(widget.rates.secondary)) widget.rates.secondary!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: widget.child,
          ),
        ),
        if (_open && windows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 9, left: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const PillPanelLabel(label: 'Usage'),
                for (final w in windows) ...[
                  const SizedBox(height: 8),
                  _UsageBar(window: w),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One rate-limit window as the screenshot's block: a title, the used percent, a
/// filled track for it, then "Resets in …".
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.window});

  final CodexWindow window;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final used = (window.usedPercent ?? 0).clamp(0, 100);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _windowTitle(window.windowMinutes),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppPalette.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$used%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFont.medium,
                color: AppPalette.textPrimary,
                fontFeatures: AppFont.tabularFigures,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // A rounded track with the used fraction filled in accent — a plain
        // Container split rather than LinearProgressIndicator so the height,
        // radius and colours match the panel exactly.
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 5,
            color: AppPalette.textFaint.withValues(alpha: 0.22),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: used / 100,
                child: Container(color: AppPalette.accent),
              ),
            ),
          ),
        ),
        if (window.resetAfterSeconds != null) ...[
          const SizedBox(height: 5),
          Text(
            'Resets in ${_resetsShort(window.resetAfterSeconds!)}',
            style: TextStyle(fontSize: 10.5, color: AppPalette.textFaint),
          ),
        ],
      ],
    );
  }
}

/// "Session (5hr)" / "Weekly (7d)" / "Monthly (30d)" — a name for the window's
/// length plus the length itself, matching how the seat's own client frames it.
String _windowTitle(int? minutes) {
  if (minutes == null || minutes <= 0) return 'Usage';
  final name = minutes <= 360
      ? 'Session'
      : minutes <= 1440
      ? 'Daily'
      : minutes <= 10080
      ? 'Weekly'
      : 'Monthly';
  return '$name (${_windowShort(minutes)})';
}

String _windowShort(int minutes) {
  if (minutes % 1440 == 0) return '${minutes ~/ 1440}d';
  if (minutes % 60 == 0) return '${minutes ~/ 60}hr';
  return '${minutes}m';
}

/// Seconds-until-reset, compact: "36m", "2hr 10m", "5d 3hr".
String _resetsShort(int seconds) {
  if (seconds <= 0) return 'now';
  final days = seconds ~/ 86400;
  if (days >= 1) {
    final hours = (seconds % 86400) ~/ 3600;
    return hours > 0 ? '${days}d ${hours}hr' : '${days}d';
  }
  final hours = seconds ~/ 3600;
  if (hours >= 1) {
    final mins = (seconds % 3600) ~/ 60;
    return mins > 0 ? '${hours}hr ${mins}m' : '${hours}hr';
  }
  return '${seconds ~/ 60}m';
}
