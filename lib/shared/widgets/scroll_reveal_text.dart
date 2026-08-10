import 'dart:async';

import 'package:flutter/material.dart';

/// How fast the line travels once it starts, in logical pixels per second.
/// Slow enough to read a title as it passes, fast enough that a long one isn't
/// a wait.
const double _speed = 46;

/// The soft edge on either side while the line is mid-travel — the tail must
/// not end in a hard vertical cut, and the head needs the same treatment once
/// it starts sliding out of view.
const double _fadeWidth = 14;

/// One line of text that reveals its own tail: given less room than it needs,
/// it slides left until the end of the string is in view, then stops there.
///
/// Built for the surfaces whose whole job is showing what a truncated row hid —
/// a chat's hover preview exists because the rail's own label ends in "…".
/// Text that already fits is drawn plainly and never moves: motion here means
/// "there is more to read", so a line that animated without hiding anything
/// would be saying something untrue.
///
/// It travels once and rests at the end rather than looping: a marquee that
/// returns to the start asks you to keep watching, and this one is answering a
/// question you already asked by hovering.
class ScrollRevealText extends StatefulWidget {
  const ScrollRevealText({
    super.key,
    required this.text,
    required this.style,
    this.strutStyle,
    this.startDelay = const Duration(milliseconds: 520),
  });

  final String text;
  final TextStyle style;

  /// Carried through to both the measurement and the line itself, so swapping a
  /// plain [Text] for this one can't shift the baseline: a row that pins its
  /// label's metrics with a strut has to keep them while the label travels.
  final StrutStyle? strutStyle;

  /// The beat before the line starts moving — long enough to read the head of
  /// the title standing still, so the reveal feels like a continuation rather
  /// than something snatched away as you land on it.
  final Duration startDelay;

  @override
  State<ScrollRevealText> createState() => _ScrollRevealTextState();
}

class _ScrollRevealTextState extends State<ScrollRevealText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _travel = AnimationController(vsync: this);
  Timer? _start;

  /// How far past its box the text runs, as last measured. Held so the schedule
  /// is only redone when the geometry genuinely changed — the measurement
  /// happens on every build, but the controller must not be reset by one.
  double _overflow = 0;

  @override
  void dispose() {
    _start?.cancel();
    _travel.dispose();
    super.dispose();
  }

  /// Restart the reveal for a newly measured [overflow]. Called after the
  /// frame, never during it: touching the controller drives listeners, and
  /// doing that mid-build is a rebuild inside a build.
  ///
  /// The mounted check is the price of that delay — a hovered row scrolled out
  /// of the rail is disposed between the build and the callback, and the
  /// controller it would reset is already gone.
  void _schedule(double overflow) {
    if (!mounted) return;
    if ((overflow - _overflow).abs() < 0.5) return;
    _overflow = overflow;
    _start?.cancel();
    _travel
      ..stop()
      ..value = 0;
    if (overflow <= 0.5) return;
    // Duration from distance, so a title one word too long and one twice the
    // width of its box travel at the same readable pace. Clamped at both ends:
    // a hair of overflow shouldn't be an imperceptible twitch, and a very long
    // title shouldn't hold you there for ten seconds.
    _travel.duration = Duration(
      milliseconds: (overflow / _speed * 1000).round().clamp(700, 4200),
    );
    _start = Timer(widget.startDelay, () {
      if (mounted) _travel.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          strutStyle: widget.strutStyle,
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflow = painter.width - constraints.maxWidth;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _schedule(overflow),
        );

        if (overflow <= 0.5) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
            strutStyle: widget.strutStyle,
          );
        }

        // Its own measured height rather than whatever the parent offers: the
        // travelling line is positioned, so nothing inside can size the box,
        // and a Row would hand it an unbounded height to fill.
        return SizedBox(
          height: painter.height,
          child: AnimatedBuilder(
            animation: _travel,
            builder: (context, _) => ClipRect(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => _edgeFade(bounds, _travel.value),
                child: Stack(
                  children: [
                    Positioned(
                      left: -overflow * _travel.value,
                      top: 0,
                      bottom: 0,
                      // The +1 is the rounding slack between the painter's
                      // measurement and the laid-out line; without it the last
                      // glyph can clip by a hair at rest.
                      width: painter.width + 1,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: widget.style,
                        strutStyle: widget.strutStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The mask over a travelling line: the head fades in as it starts to leave,
/// the tail's fade lifts as the end arrives. Both ramp over the first and last
/// slice of the travel, so at rest the line is a plain hard-edged string again.
Shader _edgeFade(Rect bounds, double t) {
  final w = bounds.width;
  if (w <= _fadeWidth * 2) {
    return const LinearGradient(
      colors: [Colors.white, Colors.white],
    ).createShader(bounds);
  }
  final head = (t * 8).clamp(0.0, 1.0);
  final tail = ((1 - t) * 8).clamp(0.0, 1.0);
  final edge = _fadeWidth / w;
  return LinearGradient(
    stops: [0, edge, 1 - edge, 1],
    colors: [
      Colors.white.withValues(alpha: 1 - head),
      Colors.white,
      Colors.white,
      Colors.white.withValues(alpha: 1 - tail),
    ],
  ).createShader(bounds);
}
