import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/grid_growth.dart';

/// Fixed motes of ambient dust — seeded once so the field is identical on every
/// run and on every machine, which a `Random()` per frame would not be.
final List<_Mote> _dust = () {
  final rng = math.Random(11);
  return List<_Mote>.generate(
    30,
    (_) => _Mote(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      size: 0.4 + rng.nextDouble() * 0.9,
      phase: rng.nextDouble() * math.pi * 2,
      speed: 0.2 + rng.nextDouble() * 0.3,
    ),
  );
}();

class _Mote {
  const _Mote({
    required this.x,
    required this.y,
    required this.size,
    required this.phase,
    required this.speed,
  });
  final double x;
  final double y;
  final double size;
  final double phase;
  final double speed;
}

/// Draws one frame of the welcome grid at [seconds] into the loop: the dust, the
/// links, the capacity flowing inward, the hub's ring, and the machines.
///
/// Takes its colours rather than reading tokens, because a painter runs outside
/// the widget that watched the theme — passing them in is what makes the picture
/// follow a Light/Dark flip (see the `AppTheme.watch` trap).
class GridGrowthPainter extends CustomPainter {
  GridGrowthPainter({
    required this.seconds,
    required this.pill,
    required this.hair,
    required this.bolt,
    required this.online,
    required this.label,
    required this.faint,
    required this.isDark,
  });

  final double seconds;
  final Color pill;
  final Color hair;
  final Color bolt;
  final Color online;
  final Color label;
  final Color faint;
  final bool isDark;

  static double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / 640).clamp(0.8, 1.3);
    final centre = Offset(size.width / 2, size.height / 2);
    // An ellipse, not a circle: this area is always wider than it is tall, so a
    // circular ring would clip top and bottom long before it filled the width.
    // The vertical share stays under the horizontal one because the outermost
    // machines sit at 1.5× these radii and carry a label above them.
    final rx = math.min(size.width * 0.26, 420.0);
    final ry = math.min(size.height * 0.26, 190.0);

    final joined = machinesJoinedAt(seconds);
    // One second of gold across every link once the last machine lands — the
    // grid read as one thing, which is the sentence the screen is making.
    final flash = (seconds > kGridFinaleAt && seconds < kGridFinaleAt + 1.5)
        ? math.pow(1 - (seconds - kGridFinaleAt) / 1.5, 2).toDouble()
        : 0.0;

    _paintDust(canvas, size);

    final points = [
      for (var i = 0; i < kWelcomeMachines.length; i++)
        _positionOf(i, centre, rx, ry),
    ];

    // The grid goes out as one layer at the seam of the loop. Fading the whole
    // picture at once — rather than each shape doing its own arithmetic — is
    // what keeps the links, the ring and the pills leaving together.
    final fade = loopFade(seconds);
    if (fade < 1) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = const Color(0xFF000000).withValues(alpha: fade),
      );
    }
    _paintLinks(canvas, points, flash);
    _paintPulses(canvas, points);
    if (seconds > kWelcomeMachines.first.joinAt) {
      _paintHub(canvas, points.first, joined, flash, scale);
    }
    _paintMachines(canvas, points, flash, scale);
    if (fade < 1) canvas.restore();
  }

  /// Where machine [i] sits this frame: its own place on the ellipse, plus a very
  /// slow rotation of the whole cluster and a small independent wobble, so the
  /// grid looks alive rather than printed.
  Offset _positionOf(int i, Offset centre, double rx, double ry) {
    final machine = kWelcomeMachines[i];
    final angle = machine.angle + seconds * 0.03;
    return Offset(
      centre.dx +
          math.cos(angle) * rx * machine.radius +
          math.sin(seconds * 0.6 + i * 1.7) * 2.4,
      centre.dy +
          math.sin(angle) * ry * machine.radius +
          math.cos(seconds * 0.5 + i) * 1.8,
    );
  }

  void _paintDust(Canvas canvas, Size size) {
    final paint = Paint();
    for (final mote in _dust) {
      final y = (mote.y + seconds * mote.speed * 0.02) % 1;
      final alpha =
          (isDark ? 0.14 : 0.09) *
          (0.55 + 0.45 * math.sin(seconds * 0.7 + mote.phase));
      paint.color = faint.withValues(alpha: alpha.clamp(0, 1));
      canvas.drawCircle(
        Offset(mote.x * size.width, y * size.height),
        mote.size,
        paint,
      );
    }
  }

  /// Every machine to the hub, plus a link to the one before it — the ring is
  /// what turns nine spokes into a mesh, and it is drawn late so the first
  /// machines read as "joining you" before they read as "a network".
  void _paintLinks(Canvas canvas, List<Offset> points, double flash) {
    final line = Paint()
      ..color = hair
      ..strokeWidth = 1;
    final lit = Paint()
      ..color = bolt.withValues(alpha: flash * 0.5)
      ..strokeWidth = 1.3;

    void link(int a, int b, double at) {
      final progress = ((seconds - at) / 0.55).clamp(0.0, 1.0);
      if (progress <= 0) return;
      final grown = _easeOut(progress);
      canvas.drawLine(
        points[a],
        Offset.lerp(points[a], points[b], grown)!,
        line,
      );
      if (flash > 0 && progress >= 1) {
        canvas.drawLine(points[a], points[b], lit);
      }
    }

    for (var i = 1; i < kWelcomeMachines.length; i++) {
      link(0, i, kWelcomeMachines[i].joinAt + 0.10);
    }
    for (var i = 2; i < kWelcomeMachines.length; i++) {
      link(i - 1, i, kWelcomeMachines[i].joinAt + 0.30);
    }
  }

  /// Capacity travelling *inward*, one mote per joined spoke. The direction is
  /// the point: what flows here is the machines' power arriving at the grid, not
  /// the user's work leaving it.
  void _paintPulses(Canvas canvas, List<Offset> points) {
    final paint = Paint();
    for (var i = 1; i < kWelcomeMachines.length; i++) {
      if (seconds < kWelcomeMachines[i].joinAt + 0.7) continue;
      final t = (seconds * 0.55 + i * 0.13) % 1;
      final eased = t * t * (3 - 2 * t);
      paint.color = bolt.withValues(alpha: 0.9 * math.sin(t * math.pi));
      canvas.drawCircle(Offset.lerp(points[i], points.first, eased)!, 2, paint);
    }
  }

  /// The hub: a breathing glow, and a ring that fills with the share of machines
  /// that have joined. The ring eases toward each new value rather than snapping,
  /// so a machine landing reads as a surge.
  void _paintHub(
    Canvas canvas,
    Offset hub,
    int joined,
    double flash,
    double scale,
  ) {
    final glowRadius =
        (58 + (0.5 + 0.5 * math.sin(seconds * 1.25)) * 10 + flash * 26) * scale;
    final intensity = (isDark ? 0.20 : 0.13) + flash * 0.22;
    canvas.drawCircle(
      hub,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            bolt.withValues(alpha: intensity),
            bolt.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: hub, radius: glowRadius)),
    );

    final ringRadius = 42 * scale;
    final bounds = Rect.fromCircle(center: hub, radius: ringRadius);
    canvas.drawCircle(
      hub,
      ringRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = hair,
    );

    final total = kWelcomeMachines.length;
    final settle =
        ((seconds - kWelcomeMachines[math.max(0, joined - 1)].joinAt) / 0.6)
            .clamp(0.0, 1.0);
    final filled =
        ((joined - 1) + _easeOut(settle)).clamp(0, total).toDouble() / total;
    canvas.drawArc(
      bounds,
      -math.pi / 2,
      filled * math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = bolt,
    );
  }

  void _paintMachines(
    Canvas canvas,
    List<Offset> points,
    double flash,
    double scale,
  ) {
    for (var i = 0; i < kWelcomeMachines.length; i++) {
      final machine = kWelcomeMachines[i];
      final age = seconds - machine.joinAt;
      if (age <= 0) continue;
      final grown = _easeOut((age / 0.55).clamp(0.0, 1.0));
      final hub = i == 0;
      final centre = points[i];

      // The arrival itself: a ring thrown off the moment it lands, so a machine
      // joining is an event and not just one more box that turned up.
      if (!hub && age < 0.85) {
        final wave = age / 0.85;
        canvas.drawCircle(
          centre,
          (10 + wave * 44) * scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = bolt.withValues(alpha: (1 - wave) * 0.45),
        );
      }

      final width = (hub ? 94.0 : 84.0) * scale * (0.88 + 0.12 * grown);
      final height = (hub ? 32.0 : 28.0) * scale * (0.88 + 0.12 * grown);
      final rect = Rect.fromCenter(
        center: centre.translate(0, (1 - grown) * 8),
        width: width,
        height: height,
      );
      final box = RRect.fromRectAndRadius(rect, const Radius.circular(9));

      canvas.drawRRect(box, Paint()..color = pill.withValues(alpha: grown));
      // The fill alone carries a machine in dark (#252525 on #181818) but not in
      // light, where the same two tokens sit 1.05:1 apart and the pill dissolves
      // into the band. The rim is what makes it a thing in both.
      canvas.drawRRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = hair.withValues(alpha: hair.a * grown),
      );
      if (hub) {
        canvas.drawRRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = bolt.withValues(alpha: grown * (0.85 + flash * 0.15)),
        );
      }

      _text(
        canvas,
        hub ? 'your grid' : machine.name,
        rect.center,
        color: (hub ? bolt : label).withValues(alpha: grown),
        size: (hub ? 12 : 11.5) * scale,
        weight: hub ? FontWeight.w600 : FontWeight.w500,
      );

      if (hub) continue;

      canvas.drawCircle(
        Offset(rect.right - 9 * scale, rect.top + 8 * scale),
        2.2 * scale,
        Paint()..color = online.withValues(alpha: grown * 0.95),
      );

      // What this machine just added to the pool, said once and then gone. The
      // rail below keeps the running total; this is only the receipt.
      if (age < 1.5) {
        _text(
          canvas,
          '+${machine.memoryGb}GB',
          Offset(
            rect.center.dx,
            rect.top - (11 + math.min(9, age * 13)) * scale,
          ),
          color: bolt.withValues(alpha: (1 - age / 1.5) * 0.9),
          size: 11 * scale,
          weight: FontWeight.w600,
        );
      }
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset centre, {
    required Color color,
    required double size,
    required FontWeight weight,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: -0.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(GridGrowthPainter old) =>
      old.seconds != seconds || old.pill != pill || old.bolt != bolt;
}
