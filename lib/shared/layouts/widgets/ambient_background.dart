import 'package:flutter/material.dart';

/// The softly-lit "wallpaper" that sits behind every glass panel.
///
/// Frosted translucency over a flat near-black would be invisible — glass needs
/// bright, saturated light to refract, the way an iOS panel lives over a
/// colorful wallpaper. A deep indigo base plus jewel-toned aurora blooms give
/// the shell that glow. Blooms are pushed into the corners so the center stays
/// calm and content on top stays readable.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1230), Color(0xFF121118), Color(0xFF0D1220)],
        ),
      ),
      child: Stack(
        children: [
          _Bloom(
            alignment: Alignment(-1.05, -1.15),
            color: Color(0xFF5B6BF5), // indigo — behind the sidebar
            diameter: 620,
            opacity: 0.55,
          ),
          _Bloom(
            alignment: Alignment(1.2, -0.9),
            color: Color(0xFF9D4EDD), // violet
            diameter: 520,
            opacity: 0.42,
          ),
          _Bloom(
            alignment: Alignment(-0.9, 1.2),
            color: Color(0xFF2DD4BF), // teal
            diameter: 540,
            opacity: 0.32,
          ),
          _Bloom(
            alignment: Alignment(1.25, 1.05),
            color: Color(0xFF3B82F6), // blue
            diameter: 560,
            opacity: 0.38,
          ),
        ],
      ),
    );
  }
}

/// A single soft radial glow — a color fading to transparent — placed off toward
/// an edge so only its edge bleeds into view, like light behind frosted glass.
class _Bloom extends StatelessWidget {
  const _Bloom({
    required this.alignment,
    required this.color,
    required this.diameter,
    required this.opacity,
  });

  final Alignment alignment;
  final Color color;
  final double diameter;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: opacity),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
