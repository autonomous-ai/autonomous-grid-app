import 'package:flutter/material.dart';

/// The app's one "this is alive" heartbeat.
///
/// The design system asks for a subtle pulse on anything long-running — "no
/// static loaders". That animation was written three separate times (the
/// playground's status LED, the login mark's glow, the model pill) and only two
/// of them honoured Reduce Motion, so the same heartbeat beat at three tempos
/// and one of them kept moving for users who had asked it not to.
///
/// [Pulse] is that primitive, extracted once: a controller that eases 0→1→0 and
/// holds still at rest when Reduce Motion is on. Build the visual yourself from
/// `t` — this owns the timing, not the look.
class Pulse extends StatefulWidget {
  const Pulse({
    super.key,
    required this.builder,
    this.duration = const Duration(milliseconds: 1600),
    this.curve = Curves.easeInOut,
    this.child,
  });

  /// Called with `t` in 0..1, sweeping up and back down forever.
  final Widget Function(BuildContext context, double t, Widget? child) builder;

  /// One half-cycle. 1600ms is the app's LED blink; the login mark breathes at
  /// 4s. Slower reads as calmer.
  final Duration duration;

  final Curve curve;

  /// Passed through to [builder] unrebuilt — hoist anything static into this.
  final Widget? child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late final Animation<double> _curved = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion parks the pulse at full strength rather than mid-fade — a
    // dot frozen at 40% opacity reads as "disabled", which is the opposite of
    // what it means.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(Pulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its own layer. This is the app's one heartbeat primitive, so the boundary
    // belongs here rather than at each call site — every visual built on it is
    // long-running by definition, and the shell keeps the rail, the bar and the
    // pane in a single layer. See the note in `status_dot.dart`.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) =>
            widget.builder(context, _curved.value, child),
        child: widget.child,
      ),
    );
  }
}

/// A soft-glowing dot that blinks to signal "live" — the status LED used by the
/// playground pill and anywhere else a thing is running.
class PulseDot extends StatelessWidget {
  const PulseDot({super.key, required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Pulse(
      builder: (context, t, _) {
        final opacity = 0.4 + 0.6 * t;
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.5 * opacity),
                blurRadius: size * 0.85,
              ),
            ],
          ),
        );
      },
    );
  }
}
