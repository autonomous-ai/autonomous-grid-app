import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../playground/logic/context_usage.dart';
import '../logic/chat_context_meter.dart';

/// The composer's context ring: how much of the model's memory this chat has
/// already filled, sitting beside the model it fills.
///
/// A ring rather than a line of numbers, because it answers the only question
/// asked of it in passing — *is this chat getting full?* — at a glance, in the
/// width of an icon. The numbers behind it are one hover away, where someone
/// who wants them will look.
///
/// Absent, not empty, when nothing reliable is known (a chat with no turns yet,
/// or a model whose context window nobody publishes): a ring filled against a
/// guess would be worse than no ring.
class ContextMeter extends ConsumerWidget {
  const ContextMeter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette/AppGlass — follow theme flips
    final usage = ref.watch(activeChatContextProvider);
    if (usage == null) return const SizedBox.shrink();
    final fraction = usage.fraction;
    if (fraction == null) return const SizedBox.shrink();

    return Tooltip(
      message: contextMeterTooltip(usage),
      child: SizedBox(
        width: _slot,
        height: _slot,
        child: Center(
          child: CustomPaint(
            size: const Size.square(_ring),
            painter: _RingPainter(
              fraction: fraction,
              track: AppGlass.hair,
              fill: _fillFor(context, fraction),
            ),
          ),
        ),
      ),
    );
  }

  /// Matches the icon buttons either side of it, so the composer's bottom strip
  /// stays one row of 32px slots.
  static const double _slot = 32;
  static const double _ring = 15;

  /// Calm until it isn't: the ring reads as chrome while there's room, warms as
  /// the window fills, and goes red only when the next few messages are what
  /// will push older ones out.
  static Color _fillFor(BuildContext context, double fraction) {
    if (fraction >= 0.95) return Theme.of(context).colorScheme.error;
    if (fraction >= 0.8) return AppPalette.warn;
    return AppPalette.accentOnSurface;
  }
}

/// What the ring says in words. Leads with the share, because that is what the
/// ring drew and what the user is checking; the raw counts follow for whoever
/// wants them. "About" whenever the figure was counted here rather than by the
/// model — the ring must never pass off an estimate as the model's own number.
String contextMeterTooltip(ContextUsage usage) {
  final percent = usage.percentUsed ?? 0;
  final used = formatTokenCount(usage.usedTokens);
  final limit = formatTokenCount(usage.limitTokens ?? 0);
  final counts = usage.estimated
      ? 'About $used of $limit tokens'
      : '$used of $limit tokens';
  return 'Chat memory\n$percent% used · ${100 - percent}% left\n$counts';
}

/// Draws the ring: a full faint circle with the used share swept over it from
/// twelve o'clock, clockwise — the way a gauge is read.
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  static const double _stroke = 2.2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - _stroke) / 2;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = track;
    canvas.drawCircle(center, radius, base);

    if (fraction <= 0) return;
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = fill;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      sweep,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}
