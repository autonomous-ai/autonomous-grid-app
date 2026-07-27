import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_overview_refresh.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import 'memory_split_bar.dart';
import 'top_bar_pill.dart';

/// The active grid at a glance: which grid you're on, and the hardware standing
/// behind it. Hovering opens a panel with the full picture — GPU memory, how
/// many requests it can serve at once, throughput, and the machines themselves.
///
/// The pill answers "where am I, and can this grid handle what I'm about to
/// ask?"; the panel answers "why". Naming the grid matters as much as the
/// numbers — with several grids joined, "which one is this?" is the question
/// asked most often, and the top bar is the only place that can answer it
/// without navigating away.
///
/// Stays fully unmounted — pill and all — while the overview loads or when
/// nothing is online, so the bar never shows a bare capsule or a row of zeroes.
/// An alternative to [HostingSummary], which shows the same two counts without
/// the grid name or the hardware panel.
class GridPowerPill extends ConsumerStatefulWidget {
  const GridPowerPill({super.key});

  @override
  ConsumerState<GridPowerPill> createState() => _GridPowerPillState();
}

class _GridPowerPillState extends ConsumerState<GridPowerPill> {
  final _link = LayerLink();
  final _controller = OverlayPortalController();
  bool _hovering = false;

  /// Open on hover, but only once the pointer has settled — a pointer crossing
  /// the bar on its way elsewhere shouldn't flash a panel open behind it.
  ///
  /// Opening the panel puts the fast-moving figures (VRAM, requests in flight)
  /// on screen, so it's also when the overview earns the quicker poll — hence
  /// [GridOverviewRefresher.setActive]. The refresher no-ops the call when
  /// nothing is watching, so the empty-pill case (which mounts the refresher but
  /// draws no panel) is safe.
  void _onEnter() {
    _hovering = true;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || !_hovering) return;
      _controller.show();
      ref.read(gridOverviewRefresherProvider).setActive(true);
    });
  }

  void _onExit() {
    _hovering = false;
    // A beat of grace so the pointer can cross the gap between pill and panel
    // without the panel closing out from under it.
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || _hovering) return;
      _controller.hide();
      ref.read(gridOverviewRefresherProvider).setActive(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final grid = ref.watch(selectedNetworkProvider);
    final power = ref.watch(gridPowerProvider);
    if (grid == null) return const SizedBox.shrink();

    // The refresher wraps the *empty* case too. Gating it behind `isEmpty`
    // would leave a grid with nothing online permanently frozen: no pill, so no
    // polling, so the first node coming up would never be noticed — precisely
    // the moment a user is waiting for the number to change.
    return GridOverviewRefresh(
      child: power.isEmpty
          ? const SizedBox.shrink()
          : MouseRegion(
              onEnter: (_) => _onEnter(),
              onExit: (_) => _onExit(),
              child: CompositedTransformTarget(
                link: _link,
                child: OverlayPortal(
                  controller: _controller,
                  overlayChildBuilder: (context) => _PowerPanel(
                    link: _link,
                    gridName: grid.name,
                    onEnter: _onEnter,
                    onExit: _onExit,
                  ),
                  child: Semantics(
                    label: _semanticsLabel(grid.name, power),
                    container: true,
                    child: TopBarPill(
                      child: _PillRow(name: grid.name, power: power),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A spoken summary for screen readers — the panel is hover-only, so everything
/// it says has to be reachable from the pill itself.
String _semanticsLabel(String name, GridPower power) {
  final parts = <String>[
    name,
    '${power.onlineNodes} ${plural(power.onlineNodes, 'computer')} hosting',
    '${power.models} ${plural(power.models, 'model')} available',
    if (power.vramGb != null) '${formatVram(power.vramGb!)} of graphics memory',
    if (power.parallel != null)
      '${power.parallel} ${plural(power.parallel!, 'task')} at once',
  ];
  return parts.join(', ');
}

class _PillRow extends StatelessWidget {
  const _PillRow({required this.name, required this.power});

  final String name;
  final GridPower power;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: AppPalette.online, size: 6, pulsing: true),
        const SizedBox(width: 8),
        // The grid name is the anchor; it gets the only full-strength text in
        // the pill so the numbers read as its supporting detail.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 132),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        const _Divider(),
        const SizedBox(width: 10),
        _Stat(
          value: '${power.onlineNodes}',
          unit: plural(power.onlineNodes, 'node'),
        ),
        const SizedBox(width: 9),
        _Stat(value: '${power.models}', unit: plural(power.models, 'model')),
        if (power.vramGb != null) ...[
          const SizedBox(width: 9),
          _Stat(value: formatVram(power.vramGb!), unit: null),
        ],
        const SizedBox(width: 6),
        Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 14,
          color: AppPalette.textFaint,
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(width: 1, height: 13, color: AppGlass.hair);
  }
}

/// One figure in the pill. Numbers are tabular so the pill keeps its width when
/// a value ticks over — otherwise the whole capsule jitters on every refresh.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.unit});

  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textSecondary,
            fontFeatures: AppFont.tabularFigures,
          ),
        ),
        if (unit != null) ...[
          const SizedBox(width: 3),
          Text(
            unit!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ],
    );
  }
}

/// The hover panel: the grid's hardware, then the machines providing it.
///
/// Anchored to the pill and pushed left so it hangs under the pill's right edge
/// rather than running off the window.
class _PowerPanel extends ConsumerWidget {
  const _PowerPanel({
    required this.link,
    required this.gridName,
    required this.onEnter,
    required this.onExit,
  });

  final LayerLink link;
  final String gridName;
  final VoidCallback onEnter;
  final VoidCallback onExit;

  static const double _width = 272;

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

    return Positioned(
      width: _width,
      child: CompositedTransformFollower(
        link: link,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 8),
        child: MouseRegion(
          onEnter: (_) => onEnter(),
          onExit: (_) => onExit(),
          child: _PanelSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _PanelHeader(name: gridName, uptimePct: uptime),
                // LOCAL MODELS — hardware nodes: the GPU-memory bar (when any
                // node reports VRAM) above one row per machine.
                if (localNodes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SectionLabel(
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
                  const _SectionLabel(label: 'Codex subscription'),
                  const SizedBox(height: 8),
                  _NodeBreakdown(nodes: subNodes, totalGb: null),
                ],
                const SizedBox(height: 11),
                _FooterStats(power: power),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.surfaceFill,
          borderRadius: BorderRadius.circular(AppCard.radius),
          border: Border.all(color: AppGlass.hair),
          boxShadow: AppGlass.shadow,
        ),
        child: Padding(padding: const EdgeInsets.all(13), child: child),
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
    required this.memoryKind,
  });

  final NodeSlice slice;
  final double totalGb;

  /// "VRAM" for a discrete GPU, "RAM" for Apple Silicon's unified memory — this
  /// node's own kind, so the figure reads "48 GB VRAM" / "32 GB RAM".
  final String memoryKind;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final pct = (slice.fraction * 100).round();
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
          width: 84,
          child: Text(
            '${formatVram(slice.gb)} $memoryKind',
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
          width: 30,
          child: Text(
            '$pct%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: AppPalette.textFaint,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}

/// The figures that aren't memory: how many tasks at once, how many models,
/// and throughput when the grid reports it. Rows rather than the bar above,
/// because none of them decompose by machine in a way worth drawing.
class _FooterStats extends StatelessWidget {
  const _FooterStats({required this.power});

  final GridPower power;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final parallel = power.parallel;
    final toks = power.throughputTokS;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 1, color: AppGlass.hair),
        const SizedBox(height: 7),
        if (parallel != null)
          _StatRow(
            label: 'Runs at once',
            value: '$parallel',
            unit: plural(parallel, 'task'),
          ),
        if (toks != null)
          _StatRow(
            label: 'Speed',
            value: formatThroughput(toks),
            unit: 'tok/s',
          ),
        _StatRow(
          label: 'Models',
          value: '${power.models}',
          unit: plural(power.models, 'model'),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: 4),
            Text(
              unit!,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Every online machine as one row, each carrying its *own* metric: a hardware
/// node its GPU-memory share (coloured to match its slice up in the bar), a
/// subscription seat its plan, and a VRAM-less hardware node whatever spec it
/// reports. One list, not a section per kind — the figure belongs on the node,
/// so "which machine, and what does it bring?" is read down a single column.
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
    final rows = <Widget>[];
    // Only VRAM nodes take a bar colour, and they sort first, so a counter that
    // advances only on them keeps each row's tick matched to its slice.
    var vramIndex = 0;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final gb = nodeVramGb(node);
      Widget row;
      if (gb != null && total != null && total > 0) {
        row = _LegendRow(
          slice: NodeSlice(
            label: labels[i],
            gb: gb,
            fraction: gb / total,
            color: sliceColor(vramIndex),
          ),
          totalGb: total,
          memoryKind: _isUnifiedMemory(node.platform) ? 'RAM' : 'VRAM',
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
              ? _PlanBadge(label: plan)
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
                    _PlanBadge(label: plan),
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
      rows.add(
        Padding(padding: const EdgeInsets.symmetric(vertical: 2.5), child: row),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
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

/// The accent tier chip a subscription row carries — same shape and accent tint
/// as the grid page's per-node plan badge, so a plan reads the same everywhere.
class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: AppPalette.accent,
        ),
      ),
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
                const _SectionLabel(label: 'Usage'),
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

/// Apple Silicon shares one unified memory pool, so a node's "GPU memory" there
/// is really system RAM; discrete GPUs (Windows/Linux/Intel Mac) have their own
/// VRAM. `macos-arm64` is the Apple Silicon tag the provider reports.
bool _isUnifiedMemory(String? platform) => (platform ?? '') == 'macos-arm64';

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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final style = TextStyle(
      fontSize: 10.5,
      fontWeight: AppFont.medium,
      letterSpacing: 0.5,
      color: AppPalette.textFaint,
    );
    return Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: style)),
        if (trailing != null)
          Text(
            trailing!,
            style: style.copyWith(
              color: AppPalette.textSecondary,
              letterSpacing: 0,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
      ],
    );
  }
}
