import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A filled ring — a share of something, drawn small enough to sit in a line of
/// text beside the figure it divides.
///
/// "2.1 TB" alone is a number without a scale: nobody knows whether that is a
/// grid running comfortably or one about to refuse work. A ring answers that
/// before the digits are read, because a part-full circle is understood without
/// being parsed.
///
/// Animates to a new value rather than jumping: the figure behind it is polled,
/// and a ring that snapped on every refresh would read as a glitch on a bar the
/// user is not looking at.
class RingGauge extends StatelessWidget {
  const RingGauge({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    this.size = 18,
    this.strokeWidth = 2.4,
  });

  /// 0–1. Clamped rather than trusted: the summed figures behind it come from
  /// separate fields on separate machines, and one of them being briefly ahead
  /// of the other must not draw a ring past full.
  final double value;
  final Color color;

  /// The unfilled remainder. Has to stay visible on its own: a track that
  /// disappears leaves an arc floating with nothing to be a share *of*.
  final Color trackColor;

  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          size: Size.square(size),
          painter: _RingPainter(
            value: v,
            color: color,
            trackColor: trackColor,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = (size.shortestSide - strokeWidth) / 2;
    final centre = rect.center;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = trackColor,
    );

    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      // From twelve o'clock, clockwise — the direction a share is read in
      // everywhere else it appears.
      -math.pi / 2,
      2 * math.pi * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}
