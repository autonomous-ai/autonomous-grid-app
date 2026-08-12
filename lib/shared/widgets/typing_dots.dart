import 'package:flutter/material.dart';

/// Three dots pulsing in sequence — the "still going" cue shown under a reply
/// while it streams in.
///
/// A reply arrives in bursts, and between bursts the text just sits there; on a
/// slow model that pause reads as the agent having stopped. The wave says it
/// hasn't. Purely decorative, so it carries no semantics of its own — the Stop
/// button and the composer's busy state are what actually report "still
/// working" to a screen reader.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.dotSize = 6});

  /// Dot colour; defaults to the theme's muted on-surface ink.
  final Color? color;

  /// Diameter of each dot. The gap between dots scales with it.
  final double dotSize;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return ExcludeSemantics(
      // Its own layer: the wave runs for the whole length of a reply, and one of
      // the two call sites is the sidebar's chat row — which sits in the shell's
      // single layer, so an unbounded repaint here drags the rail and the pane
      // through every frame of a stream. See the note in `status_dot.dart`.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: widget.dotSize * 0.6),
                Opacity(
                  opacity: _opacityFor(i),
                  child: Container(
                    width: widget.dotSize,
                    height: widget.dotSize,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// A staggered wave: each dot leads the next by a third of the cycle, its
  /// opacity riding a 0→1→0 triangle so the crest travels left to right.
  double _opacityFor(int i) {
    const min = 0.25;
    // Dart's `%` keeps the divisor's sign, so this stays in [0, 1).
    final phase = (_controller.value - i / 3) % 1.0;
    final wave = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    return min + (1 - min) * wave;
  }
}
