import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../overlord_tokens.dart';
import 'metric_chart.dart';

/// One metric inside a GPU card — a labelled big number with its unit, an
/// optional right-aligned secondary (e.g. `71%`), and the history chart. Used
/// for both the utilisation and the memory column.
class GpuMetricColumn extends StatelessWidget {
  const GpuMetricColumn({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.percent,
    required this.history,
    this.secondary,
  });

  final String label;
  final String value;
  final String unit;
  final double percent;
  final List<double> history;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final color = OverlordTokens.loadColor(percent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: OverlordTokens.sublabel,
              ),
            ),
            if (secondary != null) ...[
              const SizedBox(width: 6),
              Text(secondary!, style: OverlordTokens.sublabel),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // Scale the headline number down to fit a tight column instead of
        // truncating it — the value must always stay readable.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: _BigValue(value: value, unit: unit),
        ),
        const SizedBox(height: 8),
        MetricChart(history: history, percent: percent, color: color),
      ],
    );
  }
}

class _BigValue extends StatelessWidget {
  const _BigValue({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      softWrap: false,
      text: TextSpan(
        children: [
          TextSpan(
            text: value,
            style: const TextStyle(
              fontFamily: OverlordTokens.mono,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              height: 1,
              color: AppPalette.textPrimary,
            ),
          ),
          TextSpan(
            text: ' $unit',
            style: const TextStyle(
              fontFamily: OverlordTokens.mono,
              fontSize: 12.5,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
