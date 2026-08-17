import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/node_display.dart';
import '../../../features/network/presentation/node_dashboard_dialog.dart';
import '../../../features/provider_node/logic/serving_engines_provider.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
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
    required this.gridName,
    required this.tapGroupId,
    required this.canHost,
    required this.onEnter,
    required this.onExit,
    required this.onDismiss,
  });

  final LayerLink link;
  final String gridName;

  /// Shared with the pill, so a click on either counts as inside — the panel
  /// lives in an overlay, and without this every press on its own button would
  /// read as a tap outside and dismiss it before the press landed.
  final Object tapGroupId;

  /// Whether this user may serve on this grid. A consumer who can't is never
  /// offered the engine screen: it would only tell them they may not.
  final bool canHost;

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
          child: TapRegion(
            groupId: tapGroupId,
            child: PillPanelSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PanelHeader(name: gridName, uptimePct: uptime),
                  // LOCAL MODELS — hardware nodes: the GPU-memory bar (when any
                  // node reports VRAM) above one row per machine.
                  if (localNodes.isNotEmpty) ...[
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
                  _PanelActions(canHost: canHost, onDismiss: onDismiss),
                ],
              ),
            ),
          ),
        ),
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
          width: 100,
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
          // Wide enough for "100%" so it never wraps to a second line; softWrap
          // off + single line keeps it on the row even if a locale widens it.
          width: 36,
          child: Text(
            '$pct%',
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
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

/// What to do about any of this — the panel's foot.
///
/// The panel used to end in a lone "View dashboard" link, deliberately quiet so
/// nothing in a hover popup read as the main thing to do. That was the right
/// call for a panel that only reported; it is the wrong one now, because the
/// figures above are exactly where a user asks "can I add to this?" and the
/// screen that answers had no visible door anywhere in the app.
///
/// So the offer depends on what this machine is already doing: a computer
/// serving nothing gets the accent button, since starting an engine genuinely is
/// the one thing to do here; a computer already serving gets two equal links,
/// because then nothing is urgent and a filled button would be nagging.
class _PanelActions extends ConsumerWidget {
  const _PanelActions({required this.canHost, required this.onDismiss});

  final bool canHost;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Act first, dismiss second — both closures run from inside the panel, and
    // dismissing it unmounts the widget whose `ref` and `context` the action
    // still needs. The dialog is already pushed by the time the panel goes.
    void openEngines() {
      ref.read(shellSectionProvider.notifier).select(ShellSection.engines);
      onDismiss();
    }

    void openDashboard() {
      showNodeDashboard(context);
      onDismiss();
    }

    final dashboard = _PanelLink(label: 'View dashboard', onTap: openDashboard);
    // Nothing to offer but the numbers: this user may not serve on this grid.
    if (!canHost) return dashboard;

    // One shape in both states — what to do about this grid on the left, the way
    // to look closer on the right — so the panel's foot doesn't rearrange itself
    // depending on whether this computer happens to be serving.
    //
    // What changes is the weight, not the position. A computer already serving
    // gets a link: nothing here is urgent, and a filled button would be nagging
    // somebody who has already done the thing it asks for. A computer serving
    // nothing gets the button, because then starting an engine genuinely is the
    // one thing to do on this panel.
    return Row(
      children: [
        Expanded(
          child: ref.watch(servingEnginesProvider).isNotEmpty
              ? _PanelLink(label: 'Model engines', onTap: openEngines)
              : _RunHereButton(onTap: openEngines),
        ),
        Expanded(child: dashboard),
      ],
    );
  }
}

/// The offer to put this computer on the grid, sized to sit beside a link.
///
/// It said "Run a model on this computer" while it had the panel's full width to
/// itself. Half a width does not hold that: at 12.5px the label alone is ~175px
/// against the ~135px this column gets, so it would have ellipsized to "Run a
/// model on this…" — a button whose text is cut is worse than a shorter one.
///
/// "here" carries what the long version was for. The panel above lists other
/// people's machines, so the one word that matters is which computer this acts
/// on, and *here* is that word — it just costs four characters instead of
/// nineteen.
class _RunHereButton extends StatelessWidget {
  const _RunHereButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      // Matches [_PanelLink]'s own top inset, so the button and the link beside
      // it sit on one line rather than one riding above the other.
      padding: const EdgeInsets.only(top: 9),
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
          ),
        ),
        child: const Text(
          'Run a model here',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
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
