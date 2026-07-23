import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../overlord_tokens.dart';

/// The little graph under each metric: faint 100%/50% gridlines, a filled
/// history sparkline, and a solid bottom bar for the current reading — all in
/// the load-band color. Pure paint, no state.
class MetricChart extends StatelessWidget {
  const MetricChart({
    super.key,
    required this.history,
    required this.percent,
    required this.color,
    this.height = 52,
  });

  /// Recent samples (oldest → newest), each 0–100.
  final List<double> history;

  /// Current reading, 0–100, drawn as the solid bottom bar.
  final double percent;

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MetricChartPainter(
          history: history,
          percent: percent.clamp(0, 100).toDouble(),
          color: color,
        ),
      ),
    );
  }
}

class _MetricChartPainter extends CustomPainter {
  _MetricChartPainter({
    required this.history,
    required this.percent,
    required this.color,
  });

  final List<double> history;
  final double percent;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGridlines(canvas, size);
    _paintSparkline(canvas, size);
    _paintCurrentBar(canvas, size);
  }

  void _paintGridlines(Canvas canvas, Size size) {
    final line = Paint()
      ..color = AppPalette.divider.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    // 100% (top) and 50% (mid). Nudge the top line down so it isn't clipped.
    for (final spec in const [(0.0, '100%'), (0.5, '50%')]) {
      final double y = spec.$1 == 0 ? 0.5 : size.height * spec.$1;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      _paintLabel(canvas, spec.$2, size.width, y);
    }
  }

  void _paintLabel(Canvas canvas, String text, double right, double y) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: OverlordTokens.mono,
          fontFamilyFallback: OverlordTokens.monoFallback,
          fontSize: 8,
          color: AppPalette.textFaint,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(right - tp.width - 1, y + 1));
  }

  void _paintSparkline(Canvas canvas, Size size) {
    if (history.length < 2) return;
    final path = Path();
    final dx = size.width / (history.length - 1);
    for (var i = 0; i < history.length; i++) {
      final v = history[i].clamp(0, 100).toDouble() / 100;
      final point = Offset(i * dx, size.height - v * size.height);
      i == 0
          ? path.moveTo(point.dx, point.dy)
          : path.lineTo(point.dx, point.dy);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _paintCurrentBar(Canvas canvas, Size size) {
    const barHeight = 3.0;
    final top = size.height - barHeight;
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, barHeight),
      const Radius.circular(2),
    );
    canvas.drawRRect(track, Paint()..color = AppPalette.divider);
    final width = size.width * (percent / 100);
    if (width <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, width, barHeight),
        const Radius.circular(2),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_MetricChartPainter old) =>
      old.percent != percent ||
      old.color != color ||
      !identical(old.history, history);
}
