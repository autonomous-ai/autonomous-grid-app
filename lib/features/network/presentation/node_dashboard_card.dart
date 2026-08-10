import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/node_display.dart';
import '../logic/node_metrics.dart';

/// Colours for a gauge, by how hard the reading is pushing. Local rather than
/// palette tokens for the same reason [kSliceColors] is: these carry a
/// magnitude, not one of the app's status meanings, and a node at 90% VRAM is
/// not an *error* the way `colorScheme.error` would imply.
Color _toneColor(MetricTone tone) => switch (tone) {
  MetricTone.calm => const Color(0xFF34D399),
  MetricTone.warm => const Color(0xFFE0A93B),
  MetricTone.hot => const Color(0xFFEC6A5E),
};

/// One node's live readings: its identity, whichever gauges it reports, the
/// figures beside them, and its measured decode rate.
///
/// Everything below degrades independently. A node that reports nothing but its
/// name still renders a card — the relay knows it is online and what it serves,
/// and that is worth showing — with [missingTelemetryReason] in place of the
/// gauges rather than an unexplained blank.
class NodeDashboardCard extends StatelessWidget {
  const NodeDashboardCard({required this.node, super.key});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final bars = nodeBars(node);
    final reason = missingTelemetryReason(node);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppCard.hair),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _CardHeader(node: node),
            const SizedBox(height: 14),
            for (final bar in bars) ...[
              _Gauge(metric: bar),
              const SizedBox(height: 12),
            ],
            if (reason != null) ...[
              Text(
                reason,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppPalette.textFaint,
                ),
              ),
              const SizedBox(height: 12),
            ],
            _CardDetails(node: node),
            if (throughputLabel(node) case final tokS?) ...[
              const SizedBox(height: 12),
              _ThroughputFooter(value: tokS),
            ],
          ],
        ),
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    // No online/offline badge: the dashboard is fed by the relay's live node
    // list, so every card here is online and a per-card badge would either be a
    // branch that never fires or a label that never changes. The dialog header
    // states it once, for all of them.
    return Row(
      children: [
        Expanded(
          child: Text(
            node.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            nodeRoleSummary(node),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: AppPalette.textFaint),
          ),
        ),
      ],
    );
  }
}

/// A labelled bar: name on the left, figure on the right, track beneath. The
/// figure carries the real numbers — the bar is only there to make one node
/// comparable to the next at a glance.
class _Gauge extends StatelessWidget {
  const _Gauge({required this.metric});

  final NodeMetric metric;

  @override
  Widget build(BuildContext context) {
    final fraction = metric.fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                metric.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              metric.value,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: AppPalette.textPrimary,
              ),
            ),
          ],
        ),
        if (fraction != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 4, color: AppCard.inset),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(height: 4, color: _toneColor(metric.tone)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The figures that read better as facts than as bars: power, free memory,
/// storage, and what the node is serving. Laid out as a two-column wrap so a
/// node missing half of them closes the gaps instead of leaving holes.
class _CardDetails extends StatelessWidget {
  const _CardDetails({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    final entries = <({String label, String value})>[
      if (powerMetric(node) case final power?)
        (label: power.label, value: power.value),
      if (freeVramLabel(node) case final free?)
        (label: 'Available', value: free),
      if (storageMetric(node) case final storage?)
        (label: storage.label, value: storage.value),
      if ((node.model ?? '').isNotEmpty)
        (label: nodeEngineLabel(node.engine), value: node.model!),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns, minus the gap — computed rather than fixed so the card
        // survives the dialog being resized down on a small display.
        final columnWidth = (constraints.maxWidth - 14) / 2;
        return Wrap(
          spacing: 14,
          runSpacing: 12,
          children: [
            for (final entry in entries)
              SizedBox(
                width: columnWidth,
                child: _DetailField(label: entry.label, value: entry.value),
              ),
          ],
        );
      },
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppPalette.textFaint),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: AppPalette.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _ThroughputFooter extends StatelessWidget {
  const _ThroughputFooter({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 1, color: AppCard.hair),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              'tok/s',
              style: TextStyle(fontSize: 11, color: AppPalette.textFaint),
            ),
          ],
        ),
      ],
    );
  }
}
