import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ambient background behind every screen that comes before the app: a slow
/// aurora wash plus a faint dot grid.
///
/// One long looping controller drives the aurora; the grid is painted with it
/// and only re-rasterised as the aurora moves. Kept extremely low contrast so it
/// reads as *atmosphere*, never as decoration competing with the card in front
/// of it. Ticker-driven, so it idles when the window isn't visible, and held
/// still under Reduce Motion.
class OnboardingBackdrop extends StatefulWidget {
  const OnboardingBackdrop({super.key});

  @override
  State<OnboardingBackdrop> createState() => _OnboardingBackdropState();
}

class _OnboardingBackdropState extends State<OnboardingBackdrop>
    with SingleTickerProviderStateMixin {
  // 24s is slow enough that the drift is felt more than seen — the point is a
  // living surface, not a moving one.
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour Reduce Motion: the same wash, held still.
    if (MediaQuery.of(context).disableAnimations) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _drift,
        builder: (context, _) => CustomPaint(
          painter: _BackdropPainter(
            t: _drift.value,
            accent: AppPalette.accent,
            bolt: AppPalette.brandBolt,
            isDark: AppTheme.isDark,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.t,
    required this.accent,
    required this.bolt,
    required this.isDark,
  });

  /// Loop phase in [0, 1).
  final double t;
  final Color accent;
  final Color bolt;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    _paintAurora(canvas, size);
    _paintGrid(canvas, size);
  }

  /// Two soft accent blobs drifting on gentle Lissajous paths — one indigo, one
  /// a whisper of the brand gold — well under the content. Alpha is tiny; on a
  /// white surface even this reads clearly, so dark gets a touch more.
  void _paintAurora(Canvas canvas, Size size) {
    final twoPi = 2 * math.pi;
    // Two independent phases from the single loop so the blobs never move in
    // lockstep.
    final a = t * twoPi;
    final b = (t * twoPi) + 2.1;

    // Anchored on a diagonal — indigo top-right, gold bottom-left — so the
    // wash spans the frame rather than pooling in one corner. Each drifts around
    // its anchor on its own phase.
    final blobA = Offset(
      size.width * (0.70 + 0.08 * math.cos(a)),
      size.height * (0.28 + 0.07 * math.sin(a * 0.8)),
    );
    final blobB = Offset(
      size.width * (0.28 + 0.08 * math.cos(b * 0.7)),
      size.height * (0.72 + 0.08 * math.sin(b)),
    );

    final radius = size.shortestSide * 0.55;
    final aAlpha = isDark ? 0.10 : 0.06;
    final bAlpha = isDark ? 0.07 : 0.045;

    _blob(canvas, blobA, radius, accent.withValues(alpha: aAlpha));
    _blob(canvas, blobB, radius * 0.9, bolt.withValues(alpha: bAlpha));
  }

  void _blob(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  /// A faint dot grid — a nod to the product name. Fades out toward the edges via
  /// a radial mask so it never hits a hard border; densest, still-quiet, center.
  void _paintGrid(Canvas canvas, Size size) {
    const spacing = 34.0;
    final dot = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.035 : 0.028,
    );
    final paint = Paint()..color = dot;

    final center = Offset(size.width / 2, size.height / 2);
    final maxDist = size.shortestSide * 0.62;

    for (double x = spacing / 2; x < size.width; x += spacing) {
      for (double y = spacing / 2; y < size.height; y += spacing) {
        final d = (Offset(x, y) - center).distance;
        if (d > maxDist) continue;
        // Fade the dot as it approaches the mask edge.
        final falloff = 1 - (d / maxDist);
        canvas.drawCircle(
          Offset(x, y),
          1.1,
          paint..color = dot.withValues(alpha: dot.a * falloff),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) =>
      old.t != t || old.isDark != isDark;
}
