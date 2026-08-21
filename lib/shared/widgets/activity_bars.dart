import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three short bars rising and falling — the "something is playing" glyph, used
/// here for "the grid is working".
///
/// Deliberately **not** a spinner. A ring turning is the app's established sign
/// that a chat turn is running and will finish; throughput has no finish to
/// wait for, it is a level. Two meanings wearing one shape on the same 46px bar
/// would have to be told apart by position, which is a thing to learn rather
/// than a thing to read.
///
/// It is not a chart either, and doesn't pretend to be: the bars carry no
/// history, only how hard the grid is working *now*. [intensity] sets how tall
/// and how fast they move, so a busy grid reads as busier without anyone having
/// to compare two numbers.
///
/// At rest the bars flatten to a floor and stop dead. A stopped glyph is the
/// honest one — an animation that keeps running while nothing is happening is a
/// promise of live data that a sixty-second poll cannot keep.
class ActivityBars extends StatefulWidget {
  const ActivityBars({
    super.key,
    required this.active,
    required this.intensity,
    required this.color,
    required this.restColor,
  });

  /// Whether the grid is doing anything. False stops the animation outright —
  /// no ticker runs, so an idle grid costs the top bar nothing.
  final bool active;

  /// 0–1, how hard. Drives both the height the bars reach and how quickly they
  /// get there.
  final double intensity;

  final Color color;

  /// The flattened bars at rest. Quieter than [color]: at rest this is a
  /// state, not a signal.
  final Color restColor;

  /// The three bars, their gaps, and the tallest they get. Sized against the
  /// pill's 12.5px figures beside them — a glyph taller than its own line reads
  /// as an icon that has come loose.
  static const double barWidth = 2;
  static const double gap = 1.5;
  static const double maxHeight = 11;
  static const double minHeight = 2.5;
  static const double width = barWidth * 3 + gap * 2;

  @override
  State<ActivityBars> createState() => _ActivityBarsState();
}

class _ActivityBarsState extends State<ActivityBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _cycle,
  );

  /// One full rise-and-fall. Faster the busier it is, but never so fast it
  /// becomes a flicker in the corner of the eye.
  Duration get _cycle =>
      Duration(milliseconds: (1300 - 450 * widget.intensity).round());

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(ActivityBars old) {
    super.didUpdateWidget(old);
    if (widget.intensity != old.intensity) {
      _controller.duration = _cycle;
      // A running controller keeps its old period until it is restarted; the
      // new tempo is the point of the change.
      if (_controller.isAnimating) _controller.repeat();
    }
    if (widget.active != old.active) {
      if (widget.active) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its own layer: the bars repaint every frame while work is running, and
    // without this they would drag the whole top bar with them.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: const Size(ActivityBars.width, ActivityBars.maxHeight),
          painter: _BarsPainter(
            phase: _controller.value,
            active: widget.active,
            intensity: widget.intensity.clamp(0.0, 1.0),
            color: widget.active ? widget.color : widget.restColor,
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.phase,
    required this.active,
    required this.intensity,
    required this.color,
  });

  final double phase;
  final bool active;
  final double intensity;
  final Color color;

  /// How tall each bar gets at the top of its own swing, relative to the
  /// others. Uneven on purpose: three bars reaching the same height read as one
  /// block flexing rather than as three levels.
  static const _peaks = [0.62, 1.0, 0.48];

  /// Where each bar sits in the cycle. Spread across it so the group ripples
  /// instead of pumping in unison.
  static const _phases = [0.0, 0.33, 0.66];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final height = active ? _heightFor(i) : ActivityBars.minHeight;
      final left = i * (ActivityBars.barWidth + ActivityBars.gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left,
            size.height - height,
            ActivityBars.barWidth,
            height,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  double _heightFor(int i) {
    final wave = 0.5 + 0.5 * math.sin(2 * math.pi * (phase + _phases[i]));
    // Intensity lifts the whole group rather than only its peaks: a grid ticking
    // over at 20 tok/s should look like a grid ticking over, not like a busy one
    // caught mid-dip.
    final reach = (0.45 + 0.55 * intensity) * _peaks[i];
    final level = (0.3 + 0.7 * wave) * reach;
    return ActivityBars.minHeight +
        level * (ActivityBars.maxHeight - ActivityBars.minHeight);
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.phase != phase ||
      old.active != active ||
      old.intensity != intensity ||
      old.color != color;
}
