import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../../playground/logic/playground_models.dart' show nodeServingModel;
import '../../provider_node/logic/local_throughput.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/grid_overview_provider.dart' show gridOverviewSnapshot;
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

/// What a dashed (unmeasured) track says when hovered. Phrased as a fact about
/// the machine rather than an error, because it is one — plenty of healthy nodes
/// publish no thermal sensor at all.
const String _unmeasuredHint = 'This machine does not report this reading.';

/// One node's live readings: its identity, its gauges, the figures beside them,
/// and its measured decode rate.
///
/// Every row is always present, so two cards side by side line up label for
/// label and the eye can compare figures instead of re-reading the layout. Rows
/// the machine said nothing about print `—` over a dashed track — see
/// [NodeMetric.measured], and the note atop `node_metrics.dart` for why "never
/// measured" must never be allowed to look like "measured zero".
class NodeDashboardCard extends StatelessWidget {
  const NodeDashboardCard({required this.node, super.key});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
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
          children: [
            _CardHeader(node: node),
            const SizedBox(height: 14),
            for (final bar in nodeBars(node)) ...[
              _Gauge(metric: bar),
              const SizedBox(height: 12),
            ],
            _CardDetails(node: node),
            // Pushes the throughput to the card's foot, so a row of cards forced
            // to equal height by their tallest member keeps its big figures on
            // one line instead of floating at three different heights.
            const Spacer(),
            const SizedBox(height: 12),
            _ThroughputForNode(node: node),
          ],
        ),
      ),
    );
  }
}

/// The throughput figure for [node], filling the relay's blank on **this
/// machine** with the app's own warm-up measurement.
///
/// The relay only advertises a node's rate once it has served a real request, so
/// a machine that just started serving reads "—" until someone uses it. For the
/// local node that gap is closed by [localThroughputProvider] — a "hi" sent
/// through the grid the moment this machine is up.
///
/// Two things have to be true before that number goes on a card, because it is
/// printed beside rates the relay measured and must mean the same thing. This
/// card has to be *this machine's*; and this machine has to be the only one
/// serving the model the warm-up asked for — the relay picks between nodes
/// serving the same model and doesn't say which it picked, so with a second one
/// the honest answer is that we don't know whose speed we timed
/// (see [nodeServingModel]). Either way the relay's own blank stands.
class _ThroughputForNode extends ConsumerWidget {
  const _ThroughputForNode({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relay = throughputLabel(node);
    if (relay != kUnmeasured) return _ThroughputFooter(value: relay);

    // The local node is the one this machine joined under.
    final isLocal = node.name == ref.watch(nodeNameProvider);
    if (!isLocal) return _ThroughputFooter(value: relay);

    final warmup = ref.watch(throughputWarmupTargetProvider);
    final answered = warmup == null
        ? null
        : nodeServingModel(
            ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[],
            warmup.model,
          );
    if (answered != node.name) return _ThroughputFooter(value: relay);

    final measured = ref.watch(localThroughputProvider).value;
    if (measured == null || measured <= 0) {
      return _ThroughputFooter(value: relay);
    }
    return _ThroughputFooter(value: measured.round().toString());
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // `Expanded`, so the name absorbs every spare pixel and the summary is
        // pushed flush to the card's right edge. This was two `Flexible`s, which
        // both defaulted to flex 1 and so split the row in half — leaving the
        // summary right-aligned within its own half, floating in the middle.
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
        // Capped rather than flexible: it is laid out before the name takes the
        // remainder, so an unusually long summary would otherwise push the row
        // past the card instead of ellipsizing.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
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
    final row = Column(
      // `stretch`, so both track kinds fill the card's width. It also keeps this
      // column free of any width-measuring widget — see `_DashedTrack` on why a
      // `LayoutBuilder` cannot live inside a card.
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                color: metric.measured
                    ? AppPalette.textPrimary
                    : AppPalette.textFaint,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (metric.measured && metric.fraction != null)
          _FilledTrack(fraction: metric.fraction!, tone: metric.tone)
        else
          const _DashedTrack(),
      ],
    );
    if (metric.measured) return row;
    return Tooltip(message: _unmeasuredHint, child: row);
  }
}

/// A measured reading: solid track, coloured fill. An empty one here means a
/// real zero.
class _FilledTrack extends StatelessWidget {
  const _FilledTrack({required this.fraction, required this.tone});

  final double fraction;
  final MetricTone tone;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        children: [
          Container(height: 4, color: AppCard.inset),
          FractionallySizedBox(
            widthFactor: fraction,
            child: Container(height: 4, color: _toneColor(tone)),
          ),
        ],
      ),
    );
  }
}

/// An unmeasured reading: a broken line where a bar would be.
///
/// The texture is the point. A solid empty track is what a genuine `0%` looks
/// like, so an absent reading drawn that way would claim the node is idle. A
/// dashed one belongs to no scale at all and cannot be misread as a quantity.
///
/// Painted rather than built from a row of boxes, because the row needed a
/// `LayoutBuilder` to count how many dashes fit — and **no card may contain
/// one**. The dashboard sizes each row with `IntrinsicHeight` so cards come out
/// level, which asks every child for its intrinsic height; `LayoutBuilder`
/// refuses that question and throws mid-layout, leaving a half-built render tree
/// that the mouse tracker then re-enters. A painter has no such trouble.
class _DashedTrack extends StatelessWidget {
  const _DashedTrack();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: CustomPaint(painter: _DashPainter(color: AppCard.inset)),
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter({required this.color});

  final Color color;

  static const double _dash = 4;
  static const double _gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += _dash + _gap) {
      // The last dash is clipped to the track rather than allowed to run past
      // it, so the line ends flush with the bars above and below.
      final width = x + _dash > size.width ? size.width - x : _dash;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, width, size.height),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => oldDelegate.color != color;
}

/// The figures that read better as facts than as bars: power, free memory,
/// storage, and what the node is serving. A fixed two-column grid — every card
/// shows all four, so they line up across cards.
class _CardDetails extends StatelessWidget {
  const _CardDetails({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    final power = powerMetric(node);
    final storage = storageMetric(node);
    final entries = <({String label, String value, bool measured})>[
      (label: power.label, value: power.value, measured: power.measured),
      (
        label: 'Available',
        value: freeMemoryLabel(node),
        measured: freeMemoryLabel(node) != kUnmeasured,
      ),
      (label: storage.label, value: storage.value, measured: storage.measured),
      (
        label: nodeEngineLabel(node.engine),
        value: (node.model ?? '').isEmpty ? kUnmeasured : node.model!,
        measured: (node.model ?? '').isNotEmpty,
      ),
    ];
    // A fixed 2x2 of equal columns. Not a `Wrap` sized by a `LayoutBuilder`:
    // the dashboard levels each row with `IntrinsicHeight`, which asks every
    // child for its intrinsic height, and `LayoutBuilder` throws rather than
    // answer — see `_DashedTrack`. `Expanded` splits the width without anyone
    // having to measure it.
    return Column(
      children: [
        _DetailRow(entries: entries.take(2).toList()),
        const SizedBox(height: 12),
        _DetailRow(entries: entries.skip(2).toList()),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.entries});

  final List<({String label, String value, bool measured})> entries;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: _DetailField(
              label: entries[i].label,
              value: entries[i].value,
              measured: entries[i].measured,
            ),
          ),
        ],
      ],
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    required this.value,
    required this.measured,
  });

  final String label;
  final String value;
  final bool measured;

  @override
  Widget build(BuildContext context) {
    final field = Column(
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
            color: measured ? AppPalette.textPrimary : AppPalette.textFaint,
          ),
        ),
      ],
    );
    if (measured) return field;
    return Tooltip(message: _unmeasuredHint, child: field);
  }
}

class _ThroughputFooter extends StatelessWidget {
  const _ThroughputFooter({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final measured = value != kUnmeasured;
    final footer = Column(
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
                color: measured ? AppPalette.textPrimary : AppPalette.textFaint,
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
    if (measured) return footer;
    return Tooltip(
      message: 'This machine has not served a request yet.',
      child: footer,
    );
  }
}
