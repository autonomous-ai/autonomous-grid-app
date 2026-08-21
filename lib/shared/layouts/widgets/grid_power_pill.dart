import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_refresh.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/grid_activity.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredWindowLabel, formatCount;
import '../../theme/app_theme.dart';
import '../../widgets/activity_bars.dart';
import '../../widgets/ring_gauge.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
import 'grid_models_panel.dart';
import 'grid_power_panel.dart';
import 'grid_stat_panels.dart';
import 'top_bar_pill.dart';

/// The active grid at a glance: which grid you're on, and the hardware standing
/// behind it. Hovering — or a click, which holds it there — opens a panel with
/// the full picture: GPU memory, how many requests it can serve at once,
/// throughput, the machines themselves, and the way to add this one.
///
/// The pill answers "where am I, and can this grid handle what I'm about to
/// ask?"; the panel answers "why", and then "what can I do about it". Naming the
/// grid matters as much as the numbers — with several grids joined, "which one
/// is this?" is the question asked most often, and the top bar is the only place
/// that can answer it without navigating away.
///
/// With nothing online it becomes [_StartHostingPill] rather than vanishing: it
/// used to unmount whole, which took the last thing on screen away at the exact
/// moment the grid needed a machine. An alternative to [HostingSummary], which
/// shows the same two counts without the grid name or the hardware panel.
class GridPowerPill extends ConsumerStatefulWidget {
  const GridPowerPill({super.key});

  @override
  ConsumerState<GridPowerPill> createState() => _GridPowerPillState();
}

/// Which of the pill's panels is open.
///
/// [power] is the whole-pill panel — the grid's hardware, its machines and the
/// way to add this one — kept for the grid's name, its memory figure and the
/// chevron, which are *about the grid* rather than about one count. The other
/// three name the things their own figure counts.
enum _PanelKind { power, members, nodes, models, tokens }

/// What a stat panel hangs from: the link that places it under its figure, and
/// the key that says where that figure sits. Both, because the link alone can't
/// answer whether the panel it places still fits inside the window — see
/// [GridStatPanel.anchorKey].
typedef _FigureAnchor = ({LayerLink link, GlobalKey key});

_FigureAnchor _newFigureAnchor() => (link: LayerLink(), key: GlobalKey());

class _GridPowerPillState extends ConsumerState<GridPowerPill> {
  final _link = LayerLink();

  /// One anchor per figure, so a stat panel hangs under the number it explains
  /// rather than under the capsule as a whole. A [LayerLink] can only be
  /// attached to one target, hence one per figure.
  /// The two stretches that open the hardware panel — the grid's name at the
  /// left end of the capsule, the memory ring at the right. Each anchors the
  /// panel under itself: one link for the whole capsule opens the panel under
  /// whichever end it was pinned to, ~400px from the other.
  final _nameAnchor = _newFigureAnchor();
  final _memoryAnchor = _newFigureAnchor();

  final _memberAnchor = _newFigureAnchor();
  final _nodeAnchor = _newFigureAnchor();
  final _modelAnchor = _newFigureAnchor();
  final _tokenAnchor = _newFigureAnchor();
  final _controller = OverlayPortalController();

  /// Which end of the capsule the hardware panel hangs from — set as the
  /// pointer enters one of them, so the panel follows the pointer between the
  /// two rather than staying where it first opened.
  _FigureAnchor? _powerAnchor;

  void _powerFrom(_FigureAnchor anchor) {
    if (identical(_powerAnchor, anchor)) return;
    _powerAnchor = anchor;
    // [_onEnter] returns early when the open panel is already this kind, so
    // moving name → ring would otherwise leave the panel behind. Repainted only
    // while the panel is actually open on it.
    if (_controller.isShowing && _panel == _PanelKind.power) setState(() {});
  }

  /// Ties the pill and its panel into one tap region, so a click inside either
  /// isn't the "click outside" that dismisses a pinned panel.
  final _tapGroup = Object();

  /// What the pointer is over right now, or null when it's over none of it.
  /// Moving between two figures sets this to the new one *before* the old one's
  /// delayed close runs, which is what lets the panel swap in place instead of
  /// blinking shut and reopening.
  _PanelKind? _hovered;

  /// What the panel is currently showing.
  _PanelKind _panel = _PanelKind.power;

  /// Held open by a click, rather than by the pointer resting on the pill.
  ///
  /// Hover alone can't carry an action: reaching for a button in the panel means
  /// crossing whatever the pointer passes on the way, and a panel that closes
  /// mid-reach makes its own call to action unpressable. A pinned panel closes
  /// on a second click, on a click anywhere outside it, or when it navigates.
  bool _pinned = false;

  /// Opening the panel puts the fast-moving figures (VRAM, requests in flight)
  /// on screen, so it's also when the overview earns the quicker poll — hence
  /// [GridOverviewRefresher.setActive]. The refresher no-ops the call when
  /// nothing is watching, so the empty-pill case (which mounts the refresher but
  /// draws no panel) is safe.
  void _show() {
    _controller.show();
    ref.read(gridOverviewRefresherProvider).setActive(true);
  }

  /// Guarded on [OverlayPortalController.isShowing]: a grid whose last node
  /// drops while the panel is open swaps the pill for [_StartHostingPill], which
  /// mounts no portal — and hiding a controller with nothing attached asserts.
  /// The delayed close from [_onExit] can land on exactly that frame.
  void _hide() {
    _pinned = false;
    if (_controller.isShowing) _controller.hide();
    ref.read(gridOverviewRefresherProvider).setActive(false);
  }

  /// The pointer settled on [kind] — the pill figure, or the open panel itself.
  ///
  /// With a panel already open the swap is immediate: the pointer has crossed
  /// from one figure to the next inside a surface it never left, and re-serving
  /// the 180ms wait there would make the pill feel like it had to be re-asked.
  /// The wait is for *opening*, so a pointer crossing the top bar on its way
  /// elsewhere doesn't flash a panel open behind it.
  void _onEnter(_PanelKind kind) {
    _hovered = kind;
    if (_controller.isShowing) {
      if (_panel != kind) setState(() => _panel = kind);
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || _hovered != kind) return;
      setState(() => _panel = kind);
      _show();
    });
  }

  /// The pointer left [kind]. Closes only if it hasn't landed on another part of
  /// the pill or on the panel — the guard is the *current* hover, not this one,
  /// so figure-to-figure and pill-to-panel both survive the gap.
  void _onExit(_PanelKind kind) {
    if (_hovered == kind) _hovered = null;
    // A beat of grace so the pointer can cross the gap between pill and panel
    // without the panel closing out from under it.
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || _hovered != null || _pinned) return;
      _hide();
    });
  }

  /// A click pins whatever the pointer is on, so the panel can be read (and its
  /// buttons reached) without the pointer having to stay put.
  void _toggle() {
    if (_pinned) {
      _hide();
      return;
    }
    _pinned = true;
    setState(() => _panel = _hovered ?? _PanelKind.power);
    _show();
  }

  /// The empty pill's action. It does *not* dismiss anything first: in that
  /// state no [OverlayPortal] is mounted at all, and hiding a controller with no
  /// portal attached trips an assert rather than doing nothing.
  void _openEngines() =>
      ref.read(shellSectionProvider.notifier).select(ShellSection.engines);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final grid = ref.watch(selectedNetworkProvider);
    final power = ref.watch(gridPowerProvider);
    // The people on the grid, beside the hardware behind it. Null while the
    // roster loads or when it can't be read — see [selectedGridMemberCountProvider].
    final members = ref.watch(selectedGridMemberCountProvider);
    // Whether the grid is working, and for how long it hasn't been. Watched
    // here rather than inside the row so the idle clock keeps running for as
    // long as the pill is mounted.
    final activity = ref.watch(gridActivityProvider);
    if (grid == null) return const SizedBox.shrink();

    // The refresher wraps the *empty* case too. Gating it behind `isEmpty`
    // would leave a grid with nothing online permanently frozen: no pill, so no
    // polling, so the first node coming up would never be noticed — precisely
    // the moment a user is waiting for the number to change.
    return GridOverviewRefresh(
      child: power.isEmpty
          // Nothing online. A user allowed to host is offered the one thing that
          // fixes that; a pure consumer, who would only reach a screen telling
          // them they may not share, is offered nothing rather than a dead end.
          ? grid.canManageProvider
                ? _StartHostingPill(onTap: _openEngines)
                : const SizedBox.shrink()
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => _onEnter(_PanelKind.power),
              onExit: (_) => _onExit(_PanelKind.power),
              child: TapRegion(
                groupId: _tapGroup,
                onTapOutside: (_) {
                  if (_pinned) _hide();
                },
                child: CompositedTransformTarget(
                  link: _link,
                  child: OverlayPortal(
                    controller: _controller,
                    overlayChildBuilder: (context) =>
                        _panelFor(_panel, grid.name, grid.canManageProvider),
                    child: Semantics(
                      label: _semanticsLabel(
                        grid.name,
                        power,
                        members,
                        activity,
                      ),
                      button: true,
                      container: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggle,
                        child: TopBarPill(
                          child: _PillRow(
                            name: grid.name,
                            power: power,
                            members: members,
                            activity: activity,
                            nameAnchor: _nameAnchor,
                            memoryAnchor: _memoryAnchor,
                            onPowerFrom: _powerFrom,
                            memberAnchor: _memberAnchor,
                            nodeAnchor: _nodeAnchor,
                            modelAnchor: _modelAnchor,
                            tokenAnchor: _tokenAnchor,
                            onEnter: _onEnter,
                            onExit: _onExit,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  /// The panel [kind] asks for, anchored to the figure it belongs to.
  Widget _panelFor(
    _PanelKind kind,
    String gridName,
    bool canHost,
  ) => switch (kind) {
    _PanelKind.power => GridPowerPanel(
      link: (_powerAnchor ?? _nameAnchor).link,
      anchorKey: (_powerAnchor ?? _nameAnchor).key,
      gridName: gridName,
      tapGroupId: _tapGroup,
      canHost: canHost,
      onEnter: () => _onEnter(_PanelKind.power),
      onExit: () => _onExit(_PanelKind.power),
      onDismiss: _hide,
    ),
    // Wider than the default: the line under the list carries four figures on
    // one row ("12 requests · 600K input tokens · 400K from cache · 150K output
    // tokens"), and at the list width it ellipsized away the two that matter
    // most — the ones at the end. Grown with the type it holds (340 → 368 when
    // the panel's text went up a point): the line was already exactly full.
    _PanelKind.members => _statPanel(
      kind,
      _memberAnchor,
      GridMembersList(onDismiss: _hide),
      width: 368,
    ),
    // Wider: a node's rows carry a spec line and a live line under the name,
    // and at the list width those ellipsize to nothing worth reading.
    _PanelKind.nodes => _statPanel(
      kind,
      _nodeAnchor,
      const GridNodesList(),
      width: 358,
    ),
    // Wider than a plain list panel, and for the same reason the nodes panel is:
    // each row now ends in two figure columns, and at the list width they would
    // take the width out of the model id — the one string every row is read for,
    // and the one nothing bounds the length of.
    _PanelKind.models => _statPanel(
      kind,
      _modelAnchor,
      const GridModelsList(),
      width: 352,
    ),
    // Narrower than a list panel: four label/figure rows, none of them long. At
    // the list width the figures would drift half a panel from their words.
    _PanelKind.tokens => _statPanel(
      kind,
      _tokenAnchor,
      const GridTokensList(),
      width: 255,
    ),
  };

  Widget _statPanel(
    _PanelKind kind,
    _FigureAnchor anchor,
    Widget child, {
    double? width,
  }) => GridStatPanel(
    link: anchor.link,
    anchorKey: anchor.key,
    tapGroupId: _tapGroup,
    onEnter: () => _onEnter(kind),
    onExit: () => _onExit(kind),
    width: width ?? GridStatPanel.defaultWidth,
    child: child,
  );
}

/// The window a pill figure covers, as a suffix — " / 24h", or nothing when the
/// relay reported no span. Attached to the unit rather than the value so the
/// figure itself stays the thing the eye lands on.
String _windowSuffix(int seconds) {
  final window = answeredWindowLabel(seconds);
  return window.isEmpty ? '' : ' / $window';
}

/// A spoken summary for screen readers — the panel is pointer-driven, so
/// everything it says has to be reachable from the pill itself.
String _semanticsLabel(
  String name,
  GridPower power,
  int? members,
  GridActivity activity,
) {
  final parts = <String>[
    name,
    if (members != null)
      '$members ${plural(members, 'person', 'people')} on it',
    '${power.onlineNodes} ${plural(power.onlineNodes, 'computer')} hosting',
    '${power.models} ${plural(power.models, 'model')} available',
    // Spelled out, not the pill's shortened "1.2M": a screen reader saying "one
    // point two em" is a riddle, and this is the one place with room to say it
    // properly.
    if (power.answered case final answered?)
      '${answered.totalTokens} tokens handled, '
          '${answered.freshInputTokens} in, '
          '${answered.tokensCached} from cache, '
          '${answered.tokensOut} out'
          '${answeredWindowLabel(answered.windowSeconds).isEmpty ? '' : ' in the last ${answeredWindowLabel(answered.windowSeconds)}'}',
    // Spoken as a share when the relay reports one, because that is what the
    // ring beside the figure draws — a reader who cannot see the ring would
    // otherwise get the pool total and none of what the sighted user is told.
    if (power.vramGb case final total?)
      power.vramUsedGb == null
          ? '${formatVram(total)} of graphics memory'
          : '${formatVram(power.vramUsedGb!)} of ${formatVram(total)} '
                'graphics memory in use',
    if (power.vramUsedGb == null && power.gpuUtilPct != null)
      '${power.gpuUtilPct!.round()}% GPU load',
    if (power.parallel != null)
      '${power.parallel} ${plural(power.parallel!, 'task')} at once',
    // What the bars and their figure say, in words: the glyph is the one part
    // of the capsule with no text of its own.
    if (activity.isBusy)
      'working at about ${activity.rateTokS!.round()} tokens a second'
    else if (activity.idleFor(DateTime.now()) case final since?)
      'idle for ${since.inMinutes} ${plural(since.inMinutes, 'minute')}'
    else
      'idle',
  ];
  return parts.join(', ');
}

/// What the bar shows on a grid with nothing online: the offer to be the machine
/// that changes that.
///
/// Accent ink rather than the capsule's usual muted figures — this is the one
/// state where the pill is asking for something instead of reporting. There is
/// nothing to hover a panel over yet, so the whole pill is the button.
class _StartHostingPill extends StatelessWidget {
  const _StartHostingPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: 'Nothing is online on this grid yet',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: TopBarPill(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.zap,
                  size: 13,
                  color: AppPalette.accentOnSurface,
                ),
                const SizedBox(width: 7),
                Text(
                  'Run a model here',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: AppPalette.accentOnSurface,
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

/// The capsule's contents: who this grid is, whether it is working, and how
/// much of its memory is spoken for.
///
/// It used to print five figures in a row — members, nodes, models, input,
/// memory — each the same size and weight as the next. Five equal numbers have
/// no headline: the eye had to read all of them to find out none of them was the
/// answer, and the capsule ran ~555px doing it.
///
/// What replaced them is picked to match how fast each thing actually moves.
/// Memory is a share, so it is a ring — "2.1 TB" alone has no scale to be read
/// against. Work is a level, so it is three bars and a rate, not a chart: the
/// relay answers once a minute and the 24h total it reports moves about 0.05% in
/// that time, so any line drawn from it is flat by construction. And the three
/// counts kept their place but not their words: a glyph and a figure each,
/// which is what [_CountFigure] draws.
class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.name,
    required this.power,
    required this.members,
    required this.activity,
    required this.nameAnchor,
    required this.memoryAnchor,
    required this.onPowerFrom,
    required this.memberAnchor,
    required this.nodeAnchor,
    required this.modelAnchor,
    required this.tokenAnchor,
    required this.onEnter,
    required this.onExit,
  });

  final String name;
  final GridPower power;

  /// People on the grid, or null when the roster hasn't been read — the figure
  /// is then omitted rather than guessed at.
  final int? members;

  /// Whether the grid is working, how hard, and how long it has been quiet —
  /// see [gridActivityProvider].
  final GridActivity activity;

  /// The two stretches that open the hardware panel, each anchoring it under
  /// itself — see [_GridPowerPillState._powerAnchor].
  final _FigureAnchor nameAnchor;
  final _FigureAnchor memoryAnchor;

  /// Tells the pill which of those two the pointer just entered.
  final void Function(_FigureAnchor) onPowerFrom;

  final _FigureAnchor memberAnchor;
  final _FigureAnchor nodeAnchor;
  final _FigureAnchor modelAnchor;
  final _FigureAnchor tokenAnchor;

  final void Function(_PanelKind) onEnter;
  final void Function(_PanelKind) onExit;

  /// Where a rate sits on the glyph's 0–1 scale.
  ///
  /// Logarithmic, against a ceiling of 2000 tok/s. A grid's throughput spans
  /// three orders of magnitude — one laptop answering slowly, a room of GPUs at
  /// full tilt — and on a linear scale everything short of the biggest grid
  /// would pin the bars to the floor. The ceiling is a reading of "flat out",
  /// not a limit: past it the bars simply stay at full.
  static double _intensity(double tokS) {
    if (tokS <= 0) return 0;
    return (math.log(1 + tokS) / math.log(2001)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final vram = power.vramGb;
    final used = power.vramUsedGb;
    final util = power.gpuUtilPct;
    // What the ring is a share of, in the order the data allows. Memory in use
    // is the honest first choice — it is the figure printed right beside it, so
    // the ring and the text are the same claim. Failing that, mean GPU load,
    // which is labelled as its own percentage rather than left to be mistaken
    // for the memory figure. Failing both, no ring: an empty circle beside a
    // total would imply a measurement of zero.
    final share = (vram != null && used != null)
        ? used / vram
        : (util != null ? util / 100 : null);
    final ringIsMemory = vram != null && used != null;
    // Every part of the row sits in a hover region, and the regions touch: the
    // gaps between figures are each figure's own padding rather than a spacer
    // between them. A bare SizedBox is dead ground — the pointer crossing it
    // belongs to nothing, so the open panel would close on the way past and
    // reopen on landing.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The grid name (with the live dot after it) belongs to the grid as a
        // whole, so it keeps the hardware panel.
        _HoverTarget(
          kind: _PanelKind.power,
          anchor: nameAnchor,
          onEnter: (kind) {
            onPowerFrom(nameAnchor);
            onEnter(kind);
          },
          onExit: onExit,
          padding: const EdgeInsets.only(right: _HoverTarget._gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: AppPalette.online, size: 6, pulsing: true),
              const SizedBox(width: 8),
              // The grid name is the anchor; it gets the only full-strength text
              // in the pill so everything else reads as its supporting detail.
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
            ],
          ),
        ),
        // WORK — the glyph, what the grid is doing, and the total it has done,
        // in one hover target: they are one statement, and splitting them would
        // open two different panels from either half of the same sentence.
        _HoverTarget(
          kind: _PanelKind.tokens,
          anchor: tokenAnchor,
          onEnter: onEnter,
          onExit: onExit,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Divider(),
              const SizedBox(width: 9),
              ActivityBars(
                active: activity.isBusy,
                intensity: _intensity(activity.rateTokS ?? 0),
                color: AppPalette.accentOnSurface,
                restColor: AppPalette.textFaint,
              ),
              const SizedBox(width: 7),
              if (activity.rateTokS case final rate? when activity.isBusy)
                _Stat(value: formatRate(rate), unit: 'tok/s')
              else
                // The one figure only a resting grid can give. It replaces the
                // rate rather than sitting beside a "0 tok/s", which is a
                // number nobody reads as a state.
                Text(
                  switch (activity.idleFor(DateTime.now())) {
                    final since? => idleLabel(since),
                    null => 'idle',
                  },
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    // Not [AppPalette.textFaint], which the flattened bars
                    // beside it use: faint on the pill's fill measures 3.18:1
                    // dark / 3.33:1 light — fine for a 2px graphic, under the
                    // 4.5:1 a line of text has to clear.
                    color: AppPalette.textSecondary,
                    fontFeatures: AppFont.tabularFigures,
                  ),
                ),
              // The window total, one step quieter: it is the context for the
              // rate, not a figure of its own — and at 24 hours it is the same
              // number all afternoon.
              if (power.answered case final answered?) ...[
                const SizedBox(width: 6),
                _Stat(
                  value: formatCount(answered.freshInputTokens),
                  unit: _windowSuffix(answered.windowSeconds).trim(),
                  muted: true,
                  leading: '· ',
                ),
              ],
            ],
          ),
        ),
        // MEMORY — the ring and its figure. Back on the whole-grid panel: this
        // is the hardware, which is what that panel is.
        if (vram != null)
          _HoverTarget(
            kind: _PanelKind.power,
            onEnter: onEnter,
            onExit: onExit,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _Divider(),
                const SizedBox(width: 9),
                if (share != null) ...[
                  RingGauge(
                    value: share,
                    // Amber from the point where a grid's memory stops being
                    // headroom and starts being a constraint on the next model
                    // someone loads.
                    color: share >= 0.85 ? AppPalette.warn : AppPalette.online,
                    trackColor: AppPalette.guide,
                    size: 15,
                    strokeWidth: 2.2,
                  ),
                  const SizedBox(width: 6),
                ],
                _Stat(
                  value: ringIsMemory
                      ? formatVramShare(used, vram)
                      : formatVram(vram),
                  // The percentage is named only when it is *not* the memory
                  // figure — otherwise the ring and the "1.3 / 2.1 TB" beside it
                  // already say the same thing twice.
                  unit: ringIsMemory || util == null
                      ? null
                      : '· ${util.round()}% busy',
                ),
              ],
            ),
          ),
        // WHAT THE GRID IS MADE OF — people, machines, models. Three glyphs and
        // three figures, each its own hover target over its own list.
        _CountFigure(
          kind: _PanelKind.members,
          anchor: memberAnchor,
          icon: LucideIcons.users300,
          // Absent, not zero: the roster is a separate request and may still be
          // in flight or unreadable, and "0 people" is a claim about the grid
          // rather than about what we know of it.
          value: members == null ? null : '$members',
          semanticLabel: 'people on this grid',
          leading: true,
          onEnter: onEnter,
          onExit: onExit,
        ),
        _CountFigure(
          kind: _PanelKind.nodes,
          anchor: nodeAnchor,
          icon: LucideIcons.server300,
          value: '${power.onlineNodes}',
          semanticLabel: 'computers hosting',
          leading: members == null,
          onEnter: onEnter,
          onExit: onExit,
        ),
        _CountFigure(
          kind: _PanelKind.models,
          anchor: modelAnchor,
          icon: LucideIcons.boxes,
          value: '${power.models}',
          semanticLabel: 'models available',
          onEnter: onEnter,
          onExit: onExit,
        ),
        _HoverTarget(
          kind: _PanelKind.power,
          anchor: memoryAnchor,
          onEnter: (kind) {
            onPowerFrom(memoryAnchor);
            onEnter(kind);
          },
          onExit: onExit,
          padding: const EdgeInsets.only(left: _HoverTarget._gap),
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: AppPalette.textFaint,
          ),
        ),
      ],
    );
  }
}

/// One of the grid's three counts: a glyph, a figure, and the list behind them.
///
/// Owns its own hover rather than taking the row's. [_HoverTarget] tracks the
/// pointer to decide which *panel* to open; it never tells its child that the
/// pointer arrived, and a glyph that stays faint under the cursor reads as
/// decoration — the §hover rule the menus already follow. Both marks lift
/// together: a figure that brightens while its icon stays grey looks
/// half-disabled.
///
/// Renders nothing when [value] is null, so a count nobody has read yet leaves
/// no gap where a number should be.
class _CountFigure extends StatefulWidget {
  const _CountFigure({
    required this.kind,
    required this.anchor,
    required this.icon,
    required this.value,
    required this.semanticLabel,
    required this.onEnter,
    required this.onExit,
    this.leading = false,
  });

  final _PanelKind kind;
  final _FigureAnchor anchor;
  final IconData icon;
  final String? value;

  /// What the figure counts, for a screen reader — the word the glyph replaced.
  final String semanticLabel;

  /// Whether this is the first count on the row, and so carries the rule that
  /// separates the three of them from the telemetry before them.
  final bool leading;

  final void Function(_PanelKind) onEnter;
  final void Function(_PanelKind) onExit;

  @override
  State<_CountFigure> createState() => _CountFigureState();
}

class _CountFigureState extends State<_CountFigure> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final value = widget.value;
    if (value == null) return const SizedBox.shrink();
    return _HoverTarget(
      kind: widget.kind,
      anchor: widget.anchor,
      onEnter: widget.onEnter,
      onExit: widget.onExit,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          label: '$value ${widget.semanticLabel}',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leading) ...[
                const _Divider(),
                const SizedBox(width: 9),
              ],
              Icon(
                widget.icon,
                size: 12.5,
                color: _hovered ? AppPalette.textPrimary : AppPalette.textFaint,
              ),
              const SizedBox(width: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: AppFont.medium,
                  color: _hovered
                      ? AppPalette.textPrimary
                      : AppPalette.textSecondary,
                  fontFeatures: AppFont.tabularFigures,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One hoverable stretch of the pill: which panel it opens, and — for a figure
/// that has its own panel — the link that panel hangs from.
///
/// Its horizontal padding is the gap to its neighbour, so neighbouring targets
/// share an edge and the pointer is always inside exactly one of them.
class _HoverTarget extends StatelessWidget {
  const _HoverTarget({
    required this.kind,
    required this.onEnter,
    required this.onExit,
    required this.child,
    this.anchor,
    this.padding = const EdgeInsets.symmetric(horizontal: _gap),
  });

  /// Half the space between two neighbouring figures — each pays half, so the
  /// gap belongs to both of them and to no dead ground in between.
  static const double _gap = 4.5;

  final _PanelKind kind;

  /// Trimmed on the pill's outer edges (the first and last stretch), where the
  /// capsule's own padding already sets the inset and another half-gap would
  /// widen it.
  final EdgeInsets padding;

  /// Null for the stretches that open the whole-pill panel: that one is anchored
  /// to the capsule itself, so these carry no target of their own.
  final _FigureAnchor? anchor;

  final void Function(_PanelKind) onEnter;
  final void Function(_PanelKind) onExit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final region = MouseRegion(
      onEnter: (_) => onEnter(kind),
      onExit: (_) => onExit(kind),
      child: Padding(padding: padding, child: child),
    );
    final anchor = this.anchor;
    if (anchor == null) return region;
    return CompositedTransformTarget(
      key: anchor.key,
      link: anchor.link,
      child: region,
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
  const _Stat({
    required this.value,
    required this.unit,
    this.muted = false,
    this.leading,
  });

  final String value;
  final String? unit;

  /// A figure that is context for the one before it rather than a reading of
  /// its own — a step quieter, so the row still has exactly one thing to land
  /// on.
  final bool muted;

  /// Printed before the value, in the unit's colour. Carries the separator that
  /// ties this figure to the one it qualifies, without a [SizedBox] of dead
  /// ground between the two — every gap in this row belongs to a hover target.
  final String? leading;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final unitColor = muted
        ? AppPalette.textFaint.withValues(alpha: 0.85)
        : AppPalette.textFaint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null)
          Text(
            leading!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: unitColor,
            ),
          ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: muted ? AppPalette.textFaint : AppPalette.textSecondary,
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
              color: unitColor,
            ),
          ),
        ],
      ],
    );
  }
}
