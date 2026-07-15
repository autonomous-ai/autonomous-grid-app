import 'package:flutter/material.dart';

/// The official Google "G" mark, drawn as vector paths so the sign-in button
/// reads as a real OAuth control rather than a generic arrow icon. Four brand
/// colours (blue / green / yellow / red), scaled to [size].
///
/// Paths are the canonical 48×48 Google logo geometry, normalised to a unit box
/// and scaled — so it stays crisp at any size and needs no asset.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  // Google brand colours.
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    // The paths below are authored in the canonical 48-unit Google logo space;
    // scale the whole canvas to fit [size] so callers pick any dimension.
    final s = size.width / 48.0;
    canvas.scale(s);

    final paint = Paint()..style = PaintingStyle.fill;

    // Blue — the right arm and the horizontal bar of the "G".
    paint.color = _blue;
    canvas.drawPath(
      Path()
        ..moveTo(47.532, 24.552)
        ..cubicTo(47.532, 22.905, 47.399, 21.251, 47.115, 19.631)
        ..lineTo(24.48, 19.631)
        ..lineTo(24.48, 28.958)
        ..lineTo(37.446, 28.958)
        ..cubicTo(36.908, 31.938, 35.18, 34.575, 32.65, 36.252)
        ..lineTo(32.65, 42.303)
        ..lineTo(40.396, 42.303)
        ..cubicTo(44.944, 38.116, 47.532, 31.936, 47.532, 24.552)
        ..close(),
      paint,
    );

    // Green — the bottom curve.
    paint.color = _green;
    canvas.drawPath(
      Path()
        ..moveTo(24.48, 48.0)
        ..cubicTo(30.955, 48.0, 36.412, 45.869, 40.396, 42.303)
        ..lineTo(32.65, 36.252)
        ..cubicTo(30.503, 37.702, 27.747, 38.531, 24.489, 38.531)
        ..cubicTo(18.229, 38.531, 12.925, 34.311, 11.027, 28.628)
        ..lineTo(3.037, 28.628)
        ..lineTo(3.037, 34.864)
        ..cubicTo(7.104, 42.939, 15.373, 48.0, 24.48, 48.0)
        ..close(),
      paint,
    );

    // Yellow — the left arc.
    paint.color = _yellow;
    canvas.drawPath(
      Path()
        ..moveTo(11.018, 28.628)
        ..cubicTo(10.518, 27.148, 10.233, 25.567, 10.233, 23.941)
        ..cubicTo(10.233, 22.315, 10.518, 20.734, 11.018, 19.254)
        ..lineTo(11.018, 13.018)
        ..lineTo(3.037, 13.018)
        ..cubicTo(1.371, 16.335, 0.421, 20.084, 0.421, 23.941)
        ..cubicTo(0.421, 27.798, 1.371, 31.547, 3.037, 34.864)
        ..lineTo(11.018, 28.628)
        ..close(),
      paint,
    );

    // Red — the top curve.
    paint.color = _red;
    canvas.drawPath(
      Path()
        ..moveTo(24.48, 9.35)
        ..cubicTo(28.036, 9.35, 31.229, 10.572, 33.741, 12.966)
        ..lineTo(40.573, 6.135)
        ..cubicTo(36.401, 2.278, 30.944, 0.0, 24.48, 0.0)
        ..cubicTo(15.373, 0.0, 7.104, 5.061, 3.037, 13.018)
        ..lineTo(11.018, 19.254)
        ..cubicTo(12.925, 13.571, 18.229, 9.35, 24.48, 9.35)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GoogleGPainter oldDelegate) => false;
}
