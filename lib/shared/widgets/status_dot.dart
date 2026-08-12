import 'package:flutter/material.dart';

/// A small colored status dot with a soft glow — the online/offline indicator
/// used across the list and detail panes.
///
/// Set [pulsing] to give a live/"alive" state a slow breathing halo instead of a
/// static dot. The pulse only animates an overflowing glow, never the dot's own
/// box, so it stays cheap and never nudges neighbouring widgets.
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.size = 9,
    this.pulsing = false,
  });

  final Color color;
  final double size;

  /// When true, a halo breathes out behind the dot to signal live activity.
  /// Defaults to false so every existing call site stays static.
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5),
        ],
      ),
    );
    if (!pulsing) return dot;
    return _PulseHalo(color: color, size: size, child: dot);
  }
}

/// A soft halo that expands and fades behind [child] on an endless loop — the
/// "alive" micro-interaction. Sits in an [IgnorePointer] and centres the halo so
/// it grows around the dot without shifting layout.
class _PulseHalo extends StatefulWidget {
  const _PulseHalo({
    required this.color,
    required this.size,
    required this.child,
  });

  final Color color;
  final double size;
  final Widget child;

  @override
  State<_PulseHalo> createState() => _PulseHaloState();
}

class _PulseHaloState extends State<_PulseHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honor Reduce Motion — a still dot instead of a breathing one, matching the
    // rest of the app's animated marks.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // With Reduce Motion on, the controller is stopped at 0 — the halo would
    // sit at full size and full opacity, a solid disc around the dot. Drop it
    // entirely and show just the dot.
    if (MediaQuery.of(context).disableAnimations) return widget.child;

    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Its own layer, and the top bar is why.
          //
          // The halo repaints every frame for as long as the dot is on screen,
          // and `GridPowerPill` — the one call site that sets `pulsing` — lives
          // in `AppTopBar`, which is mounted for the whole session. The shell
          // puts the sidebar, this bar and the open pane in one layer
          // (`home_shell.dart`: a plain Row/Column, no boundary anywhere), so
          // without this the breathing dot dirtied all three sixty times a
          // second, forever, and the engine never got to idle.
          //
          // Outside the Transform on purpose: the layer has to hold the scaled
          // halo, which deliberately overflows the dot's box.
          RepaintBoundary(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value; // 0..1
                  final scale = 1 + t * 1.6;
                  final opacity = (1 - t) * 0.45;
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color.withValues(alpha: opacity),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}
