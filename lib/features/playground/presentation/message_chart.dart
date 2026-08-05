import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chart_spec.dart';

/// How tall a chart is drawn in the transcript. Fixed, because a chart that
/// grew with its data would push the reply it belongs to off the screen.
const double _plotHeight = 180;

/// Room under the plot for the labels along the bottom.
const double _labelStrip = 22;

/// Room to the left for the value scale.
const double _scaleWidth = 44;

/// A chart drawn from a ```chart block in a reply.
///
/// Drawn rather than fetched or embedded: no webview, no chart package, nothing
/// that leaves the process. The transcript is offline by design and a chart is a
/// few axes and some rectangles.
class MessageChart extends StatelessWidget {
  const MessageChart({super.key, required this.spec});

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final colors = _seriesColors(spec.series.length);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spec.title case final title?) ...[
            Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: AppFont.medium,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: _plotHeight + _labelStrip,
            child: CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(
                spec: spec,
                colors: colors,
                axis: AppPalette.divider,
                ink: AppPalette.textFaint,
                labelStyle: theme.textTheme.labelSmall!.copyWith(
                  color: AppPalette.textFaint,
                ),
              ),
            ),
          ),
          if (spec.series.length > 1) ...[
            const SizedBox(height: 8),
            _Legend(spec: spec, colors: colors),
          ],
        ],
      ),
    );
  }
}

/// The names beside their colours — only drawn when there is more than one
/// series, since a legend of one is a caption repeating the title.
class _Legend extends StatelessWidget {
  const _Legend({required this.spec, required this.colors});

  final ChartSpec spec;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (var i = 0; i < spec.series.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: colors[i],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                spec.series[i].name.isEmpty
                    ? 'Series ${i + 1}'
                    : spec.series[i].name,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The categorical colours, in the order series are drawn. Taken from the app's
/// own accent family rather than a chart library's defaults, so a chart in a
/// reply looks like it belongs to the app it is in.
List<Color> _seriesColors(int count) {
  const palette = [
    Color(0xFF3B82F6),
    Color(0xFFF59E0B),
    Color(0xFF10B981),
    Color(0xFFEF4444),
    Color(0xFF8B5CF6),
    Color(0xFF14B8A6),
  ];
  return [for (var i = 0; i < count; i++) palette[i % palette.length]];
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.spec,
    required this.colors,
    required this.axis,
    required this.ink,
    required this.labelStyle,
  });

  final ChartSpec spec;
  final List<Color> colors;
  final Color axis;
  final Color ink;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      _scaleWidth,
      0,
      size.width - _scaleWidth,
      size.height - _labelStrip,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    final (low, high) = _bounds();
    _paintGrid(canvas, plot, low, high);
    if (spec.kind == ChartKind.bar) {
      _paintBars(canvas, plot, low, high);
    } else {
      _paintLines(canvas, plot, low, high);
    }
    _paintLabels(canvas, plot);
  }

  /// The value range the axis covers: always including zero, and never a flat
  /// line — a chart of six identical numbers still has to draw something.
  (double, double) _bounds() {
    final high = spec.maxValue;
    final low = spec.minValue;
    if (high == low) return (low, low + 1);
    return (low, high);
  }

  double _y(Rect plot, double value, double low, double high) =>
      plot.bottom - ((value - low) / (high - low)) * plot.height;

  void _paintGrid(Canvas canvas, Rect plot, double low, double high) {
    final line = Paint()
      ..color = axis
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final value = low + (high - low) * (i / 2);
      final y = _y(plot, value, low, high);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), line);
      _text(
        canvas,
        _formatValue(value),
        Offset(0, y - labelStyle.fontSize! - 1),
        maxWidth: _scaleWidth - 6,
        align: TextAlign.right,
      );
    }
  }

  void _paintBars(Canvas canvas, Rect plot, double low, double high) {
    final groups = spec.labels.length;
    final slot = plot.width / groups;
    final barWidth = (slot * 0.7) / spec.series.length;
    final zeroY = _y(plot, low < 0 ? 0 : low, low, high);

    for (var s = 0; s < spec.series.length; s++) {
      final paint = Paint()..color = colors[s];
      final values = spec.series[s].values;
      for (var i = 0; i < values.length; i++) {
        final left = plot.left + slot * i + slot * 0.15 + barWidth * s;
        final top = _y(plot, values[i], low, high);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(
              left,
              top.clamp(plot.top, zeroY),
              left + barWidth,
              zeroY,
            ),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          paint,
        );
      }
    }
  }

  void _paintLines(Canvas canvas, Rect plot, double low, double high) {
    final step = spec.labels.length == 1
        ? plot.width
        : plot.width / (spec.labels.length - 1);
    for (var s = 0; s < spec.series.length; s++) {
      final values = spec.series[s].values;
      if (values.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final point = Offset(
          plot.left + step * i,
          _y(plot, values[i], low, high),
        );
        i == 0
            ? path.moveTo(point.dx, point.dy)
            : path.lineTo(point.dx, point.dy);
        canvas.drawCircle(point, 2.5, Paint()..color = colors[s]);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[s]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// The labels along the bottom, thinned until they fit — an axis of
  /// overlapping text reads as a smudge, and a smudge is worse than every third
  /// label.
  void _paintLabels(Canvas canvas, Rect plot) {
    final slot = plot.width / spec.labels.length;
    final every = (60 / slot).ceil().clamp(1, spec.labels.length);
    for (var i = 0; i < spec.labels.length; i += every) {
      _text(
        canvas,
        spec.labels[i],
        Offset(plot.left + slot * i, plot.bottom + 5),
        maxWidth: slot * every,
        align: TextAlign.center,
      );
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    required double maxWidth,
    required TextAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: labelStyle),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth < 0 ? 0 : maxWidth);
    painter.paint(canvas, at);
  }

  /// Whole numbers without a decimal tail, fractions to one place — "1200" and
  /// "0.5", never "1200.0".
  String _formatValue(double value) => value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.spec != spec || old.colors != colors || old.ink != ink;
}
