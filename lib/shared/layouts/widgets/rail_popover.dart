import 'package:flutter/material.dart';

import 'grid_stat_panels.dart';

/// A figure on the status rail that opens a panel above itself.
///
/// The rail's own hover language, in one place: a beat before it opens (so a
/// pointer crossing the strip on its way elsewhere doesn't flash a panel behind
/// it), a beat of grace on the way out (so the pointer can cross the gap into
/// the panel), and a click that **pins** it open — because reaching for
/// anything inside a panel means leaving the figure that opened it.
///
/// [GridPowerReadout] keeps its own copy of this and deliberately: it juggles
/// five panels that swap in place as the pointer crosses between figures, which
/// is a different problem from opening one. This is for the single-panel case,
/// and exists so the second one didn't become a second set of timings to keep
/// in step with the first.
class RailPopover extends StatefulWidget {
  const RailPopover({
    super.key,
    required this.child,
    required this.panel,
    this.width = GridStatPanel.defaultWidth,
  });

  /// What sits on the rail and opens the panel.
  final Widget child;

  /// What the panel says. Built on every open, so it reads whatever state is
  /// current rather than what was current when the pointer arrived.
  final Widget Function() panel;

  final double width;

  @override
  State<RailPopover> createState() => _RailPopoverState();
}

class _RailPopoverState extends State<RailPopover> {
  final _link = LayerLink();
  final _anchorKey = GlobalKey();
  final _controller = OverlayPortalController();

  /// Ties the figure and its panel into one tap region, so a click inside
  /// either isn't the "click outside" that dismisses a pinned panel.
  final _tapGroup = Object();

  /// Whether the pointer is on the figure or on the panel — the guard both
  /// delayed callbacks read, so crossing the gap between the two survives it.
  bool _hovered = false;

  /// Held open by a click rather than by the pointer resting on it.
  bool _pinned = false;

  void _onEnter() {
    _hovered = true;
    if (_controller.isShowing) return;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || !_hovered || _controller.isShowing) return;
      _controller.show();
    });
  }

  void _onExit() {
    _hovered = false;
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || _hovered || _pinned) return;
      _hide();
    });
  }

  void _hide() {
    _pinned = false;
    if (_controller.isShowing) _controller.hide();
  }

  void _toggle() {
    if (_pinned) {
      _hide();
      return;
    }
    _pinned = true;
    if (!_controller.isShowing) _controller.show();
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: _tapGroup,
    onTapOutside: (_) {
      if (_pinned) _hide();
    },
    child: OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (context) => GridStatPanel(
        link: _link,
        anchorKey: _anchorKey,
        tapGroupId: _tapGroup,
        width: widget.width,
        onEnter: _onEnter,
        onExit: _onExit,
        child: widget.panel(),
      ),
      child: CompositedTransformTarget(
        key: _anchorKey,
        link: _link,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _onEnter(),
          onExit: (_) => _onExit(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}
