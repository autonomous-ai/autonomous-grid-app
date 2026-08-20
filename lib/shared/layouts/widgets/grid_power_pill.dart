import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_refresh.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/node_metrics.dart'
    show answeredWindowLabel, formatCount;
import '../../theme/app_theme.dart';
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
  final _memberAnchor = _newFigureAnchor();
  final _nodeAnchor = _newFigureAnchor();
  final _modelAnchor = _newFigureAnchor();
  final _tokenAnchor = _newFigureAnchor();
  final _controller = OverlayPortalController();

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
                      label: _semanticsLabel(grid.name, power, members),
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
      link: _link,
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
      const GridMembersList(),
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
String _semanticsLabel(String name, GridPower power, int? members) {
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
    if (power.vramGb != null) '${formatVram(power.vramGb!)} of graphics memory',
    if (power.parallel != null)
      '${power.parallel} ${plural(power.parallel!, 'task')} at once',
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

class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.name,
    required this.power,
    required this.members,
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

  final _FigureAnchor memberAnchor;
  final _FigureAnchor nodeAnchor;
  final _FigureAnchor modelAnchor;
  final _FigureAnchor tokenAnchor;

  final void Function(_PanelKind) onEnter;
  final void Function(_PanelKind) onExit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Every part of the row sits in a hover region, and the regions touch: the
    // gaps between figures are each figure's own padding rather than a spacer
    // between them. A bare SizedBox is dead ground — the pointer crossing it
    // belongs to nothing, so the open panel would close on the way past and
    // reopen on landing.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The grid name (with the live dot and the rule after it) belongs to the
        // grid as a whole, so it keeps the hardware panel.
        _HoverTarget(
          kind: _PanelKind.power,
          onEnter: onEnter,
          onExit: onExit,
          padding: const EdgeInsets.only(right: _HoverTarget._gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: AppPalette.online, size: 6, pulsing: true),
              const SizedBox(width: 8),
              // The grid name is the anchor; it gets the only full-strength text
              // in the pill so the numbers read as its supporting detail.
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
              const SizedBox(width: 5),
            ],
          ),
        ),
        // People first, then the machines: the pill reads "who is on this grid,
        // and what is standing behind it" — and the count nearest the name is
        // the one that belongs to the grid rather than to its hardware.
        if (members case final count?)
          _HoverTarget(
            kind: _PanelKind.members,
            anchor: memberAnchor,
            onEnter: onEnter,
            onExit: onExit,
            child: _Stat(value: '$count', unit: plural(count, 'member')),
          ),
        _HoverTarget(
          kind: _PanelKind.nodes,
          anchor: nodeAnchor,
          onEnter: onEnter,
          onExit: onExit,
          child: _Stat(
            value: '${power.onlineNodes}',
            unit: plural(power.onlineNodes, 'node'),
          ),
        ),
        _HoverTarget(
          kind: _PanelKind.models,
          anchor: modelAnchor,
          onEnter: onEnter,
          onExit: onExit,
          child: _Stat(
            value: '${power.models}',
            unit: plural(power.models, 'model'),
          ),
        ),
        // Memory and the work done are the grid's own headline figures, not
        // lists of anything — they keep the hardware panel, where the bar breaks
        // memory down by machine.
        // Before the memory figure: memory is what the grid *could* do, this is
        // what it actually did. Its own hover target, so asking about the work
        // opens the four token figures rather than the whole hardware panel —
        // and absent, not zero, when no node reported a rollup.
        //
        // Input alone on the pill, at the repo owner's call. It is the bigger of
        // the two figures and the one that moves first when a grid gets busy —
        // work arrives before it is answered. The trade-off is worth knowing:
        // output is the half where a machine's *time* goes, so a grid reading a
        // great deal and generating little now reads as busier on this bar than
        // it is working. The panel behind the hover carries all four figures, so
        // nothing is lost, only reordered.
        //
        // `freshInputTokens`, never `tokensIn`: the panel this expands into
        // prints cache hits on their own row, and a pill totalling both would
        // not add up to the rows it opens.
        if (power.answered case final answered?)
          _HoverTarget(
            kind: _PanelKind.tokens,
            anchor: tokenAnchor,
            onEnter: onEnter,
            onExit: onExit,
            child: _Stat(
              value: formatCount(answered.freshInputTokens),
              unit: 'input${_windowSuffix(answered.windowSeconds)}',
            ),
          ),
        _HoverTarget(
          kind: _PanelKind.power,
          onEnter: onEnter,
          onExit: onExit,
          padding: const EdgeInsets.only(left: _HoverTarget._gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (power.vramGb != null) ...[
                _Stat(value: formatVram(power.vramGb!), unit: null),
                const SizedBox(width: 6),
              ],
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: AppPalette.textFaint,
              ),
            ],
          ),
        ),
      ],
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
