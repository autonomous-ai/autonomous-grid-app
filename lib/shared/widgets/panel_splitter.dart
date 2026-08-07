import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The seam between two panels, and the handle for moving it.
///
/// Replaces the plain `Divider` at a panel's edge: it draws the same hairline,
/// but takes the pointer's cursor while it's over it and reports the drag.
///
/// **The band is wider than the line it draws.** A 1px target is one a user has
/// to hunt for; the rule stays hairline-thin so nothing about the layout looks
/// heavier, while [_band] logical pixels around it accept the pointer. That gap
/// between what you see and what you can grab is the whole trick, and it is why
/// this can't just be a `Divider` with a `MouseRegion` on it.
class PanelSplitter extends StatefulWidget {
  const PanelSplitter({
    super.key,
    required this.axis,
    required this.onDrag,
    this.onReset,
  });

  /// Which way the seam runs. [Axis.vertical] is an upright rule between two
  /// side-by-side panels, dragged left and right.
  final Axis axis;

  /// How far the seam moved since the last report, in logical pixels — positive
  /// right (or down). What that does to a panel's size is the caller's to
  /// decide: it depends which side of the seam the panel is on.
  final ValueChanged<double> onDrag;

  /// Put the panel back to the size the app would have chosen. Double-click,
  /// the desktop convention — and the way out for anyone who has dragged a
  /// panel somewhere useless.
  final VoidCallback? onReset;

  /// How much of the pointer's space the seam claims. Comfortably grabbable
  /// without swallowing clicks meant for what's on either side.
  static const double _band = 7;

  @override
  State<PanelSplitter> createState() => _PanelSplitterState();
}

class _PanelSplitterState extends State<PanelSplitter> {
  bool _hovered = false;
  bool _dragging = false;

  bool get _lit => _hovered || _dragging;

  bool get _isVertical => widget.axis == Axis.vertical;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Accent as *ink* is the `accentOnSurface` variant: `accent` is a fill
    // colour and measures 2.6:1 drawn as a line on a dark pane.
    final line = _lit ? AppPalette.accentOnSurface : AppPalette.divider;

    final rule = AnimatedContainer(
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      width: _isVertical ? 1 : double.infinity,
      height: _isVertical ? double.infinity : 1,
      color: line,
    );

    return MouseRegion(
      cursor: _isVertical
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Measured: the default (`start`) throws away the movement that got the
        // recogniser past its slop, so the seam ends up a few pixels behind the
        // cursor and stays there for the rest of the drag. `down` counts that
        // movement, and a seam has to sit under the pointer that is dragging it.
        dragStartBehavior: DragStartBehavior.down,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart: _isVertical ? _start : null,
        onHorizontalDragUpdate: _isVertical
            ? (d) => widget.onDrag(d.delta.dx)
            : null,
        onHorizontalDragEnd: _isVertical ? _end : null,
        onHorizontalDragCancel: _isVertical ? _cancel : null,
        onVerticalDragStart: _isVertical ? null : _start,
        onVerticalDragUpdate: _isVertical
            ? null
            : (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: _isVertical ? null : _end,
        onVerticalDragCancel: _isVertical ? null : _cancel,
        child: SizedBox(
          width: _isVertical ? PanelSplitter._band : null,
          height: _isVertical ? null : PanelSplitter._band,
          child: Center(child: rule),
        ),
      ),
    );
  }

  void _start(DragStartDetails _) => setState(() => _dragging = true);

  void _end(DragEndDetails _) => setState(() => _dragging = false);

  void _cancel() => setState(() => _dragging = false);
}
