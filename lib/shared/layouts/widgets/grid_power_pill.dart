import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_refresh.dart';
import '../../../features/network/logic/grid_power_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
import 'grid_power_panel.dart';
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

class _GridPowerPillState extends ConsumerState<GridPowerPill> {
  final _link = LayerLink();
  final _controller = OverlayPortalController();

  /// Ties the pill and its panel into one tap region, so a click inside either
  /// isn't the "click outside" that dismisses a pinned panel.
  final _tapGroup = Object();

  bool _hovering = false;

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

  /// Open on hover, but only once the pointer has settled — a pointer crossing
  /// the bar on its way elsewhere shouldn't flash a panel open behind it.
  void _onEnter() {
    _hovering = true;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || !_hovering) return;
      _show();
    });
  }

  void _onExit() {
    _hovering = false;
    // A beat of grace so the pointer can cross the gap between pill and panel
    // without the panel closing out from under it.
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || _hovering || _pinned) return;
      _hide();
    });
  }

  void _toggle() {
    if (_pinned) {
      _hide();
      return;
    }
    _pinned = true;
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
              onEnter: (_) => _onEnter(),
              onExit: (_) => _onExit(),
              child: TapRegion(
                groupId: _tapGroup,
                onTapOutside: (_) {
                  if (_pinned) _hide();
                },
                child: CompositedTransformTarget(
                  link: _link,
                  child: OverlayPortal(
                    controller: _controller,
                    overlayChildBuilder: (context) => GridPowerPanel(
                      link: _link,
                      gridName: grid.name,
                      tapGroupId: _tapGroup,
                      canHost: grid.canManageProvider,
                      onEnter: _onEnter,
                      onExit: _onExit,
                      onDismiss: _hide,
                    ),
                    child: Semantics(
                      label: _semanticsLabel(grid.name, power),
                      button: true,
                      container: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggle,
                        child: TopBarPill(
                          child: _PillRow(name: grid.name, power: power),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A spoken summary for screen readers — the panel is pointer-driven, so
/// everything it says has to be reachable from the pill itself.
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
