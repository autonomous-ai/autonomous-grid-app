import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// Blocked state when no model can answer yet. Points provider-capable users to
/// the Engines tab to start one; pure consumers are told to wait for a provider.
/// Shared by the Playground dialog and the Chat tab — the caller supplies
/// [onGoToEngines] (which may pop a dialog first, then navigate).
///
/// This isn't an error screen — it's a *system state* (the grid is idle, waiting
/// for an engine), so it reads as "not started yet", not "something broke": a
/// depth-lit robot mark inside a breathing accent ring, a status pill naming the
/// state, and a clear primary action.
class NoModelYet extends StatelessWidget {
  const NoModelYet({
    super.key,
    required this.canManage,
    required this.onGoToEngines,
  });

  final bool canManage;
  final VoidCallback onGoToEngines;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads AppPalette tokens
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _EngineMark(),
            const SizedBox(height: 22),
            _StatusPill(canManage: canManage),
            const SizedBox(height: 16),
            Text(
              canManage ? 'No engine is running yet' : 'Waiting for a model',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              canManage
                  ? 'Start an engine on this grid to open the chat and talk to a '
                        'model.'
                  : 'Wait for someone on this grid to bring a model online, or '
                        'ask the grid owner to run one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
            if (canManage) ...[
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onGoToEngines,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Start an engine'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The robot mark: a dark rounded chip with a warm rim, sitting inside two faint
/// accent rings, with a water-ripple that radiates out from the chip so the idle
/// state reads as alive-and-pinging rather than disabled. The ripple stops under
/// `MediaQuery.disableAnimations` (Reduce Motion), leaving the two static rings.
class _EngineMark extends StatefulWidget {
  const _EngineMark();

  @override
  State<_EngineMark> createState() => _EngineMarkState();
}

class _EngineMarkState extends State<_EngineMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honor Reduce Motion — a still mark instead of a breathing one.
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
    // Rebuild on theme flip: this widget is created `const` by its parent, so the
    // parent's own AppTheme.watch can't reach it (Flutter short-circuits the
    // reference-identical child). Watching here is what makes the chip's tokens
    // (AppCard.inset, AppPalette.accent) follow light/dark. See AppTheme.watch.
    AppTheme.watch(context);
    const tileSize = 62.0;
    const fieldSize = 176.0; // holds the ring + ripple field
    final animate = !MediaQuery.of(context).disableAnimations;

    return SizedBox(
      width: fieldSize,
      height: fieldSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Two static rings + a water-ripple that expands through the inner one.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => CustomPaint(
                size: const Size(fieldSize, fieldSize),
                painter: _RippleRingsPainter(
                  progress: _controller.value,
                  animate: animate, // Reduce Motion → just the one static ring
                  accent: AppPalette.accent,
                ),
              ),
            ),
          ),
          // The engine chip: a lifted surface tile with a faint accent rim,
          // holding the robot glyph — the mark the ripple radiates out from. Uses
          // the surface token so it reads as *raised* on both grounds (white on
          // light, a soft charcoal on dark) instead of sinking into the page.
          Container(
            width: tileSize,
            height: tileSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: AppGlass.surfaceFill,
              border: Border.all(
                color: AppPalette.accent.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: AppCard.shadow,
            ),
            child: Icon(
              Icons.smart_toy_outlined,
              size: 30,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the idle field behind the engine mark: one faint static accent ring,
/// plus a "water ripple" — an accent ring that grows from the chip outward and
/// fades as it expands, like a drop hitting water — so the idle state reads as
/// gently pinging. [progress] is the controller's 0→1 value driving the ripple's
/// radius.
class _RippleRingsPainter extends CustomPainter {
  const _RippleRingsPainter({
    required this.progress,
    required this.animate,
    required this.accent,
  });

  final double progress;
  final bool animate;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2 - 1;
    final ringR = maxR * 0.58; // the single quiet ring hugging the chip
    final outerR = maxR; // how far the ripple travels before it's gone

    // The one quiet base ring.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.28);
    canvas.drawCircle(center, ringR, ringPaint);

    if (!animate) return; // Reduce Motion — the static ring only

    // The ripple: a ring that expands from just outside the chip out past the
    // inner ring, brightest early and fading to nothing at the end of its travel
    // — a single wavefront that repeats each cycle.
    const startR = 40.0; // just outside the chip
    final rippleR = startR + (outerR - startR) * progress;
    // Ease the fade so it's strong near the chip and gone by the outer edge.
    final fade = (1 - progress) * (1 - progress);
    final ripplePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = accent.withValues(alpha: 0.55 * fade);
    canvas.drawCircle(center, rippleR, ripplePaint);

    // A second wavefront half a cycle behind, so the ping feels continuous.
    final p2 = (progress + 0.5) % 1.0;
    final rippleR2 = startR + (outerR - startR) * p2;
    final fade2 = (1 - p2) * (1 - p2);
    ripplePaint.color = accent.withValues(alpha: 0.55 * fade2);
    canvas.drawCircle(center, rippleR2, ripplePaint);
  }

  @override
  bool shouldRepaint(_RippleRingsPainter old) =>
      old.progress != progress ||
      old.animate != animate ||
      old.accent != accent;
}

/// A monospace-feeling status chip naming the state: amber "engine idle" for a
/// manager (they can act), a neutral "waiting" for a consumer (they can't). The
/// LED dot blinks unless Reduce Motion is on.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.canManage});

  final bool canManage;

  @override
  Widget build(BuildContext context) {
    // Amber = "idle, ready to start"; grey = "nothing you can do yet".
    final tone = canManage ? AppPalette.warn : AppPalette.offline;
    final label = canManage ? 'ENGINE IDLE' : 'WAITING FOR PROVIDER';

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: tone.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: tone),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: tone,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pill's status LED — a soft-glowing dot that blinks to signal "live", held
/// still when Reduce Motion is on.
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1;
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity = 0.4 + 0.6 * _controller.value;
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: opacity),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5 * opacity),
                blurRadius: 5,
              ),
            ],
          ),
        );
      },
    );
  }
}
