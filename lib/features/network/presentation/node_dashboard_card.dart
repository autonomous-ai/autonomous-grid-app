import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

/// One node's live readings: its identity — what it is called *and what it is* —
/// its gauges, the figures beside them, and its measured decode rate.
///
/// Every row is always present, so two cards side by side line up label for
/// label and the eye can compare figures instead of re-reading the layout. Rows
/// the machine said nothing about print `—` over a hairline instead of a run of
/// segments — see [NodeMetric.measured], and the note atop `node_metrics.dart`
/// for why "never measured" must never be allowed to look like "measured zero".
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
    final hardware = nodeHardwareName(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // `Expanded`, so the name absorbs every spare pixel and the summary
            // is pushed flush to the card's right edge. This was two
            // `Flexible`s, which both defaulted to flex 1 and so split the row
            // in half — leaving the summary right-aligned within its own half,
            // floating in the middle.
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
            // Capped rather than flexible: it is laid out before the name takes
            // the remainder, so an unusually long summary would otherwise push
            // the row past the card instead of ellipsizing.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                // How much this machine takes on at once. The model *count*
                // used to sit here and has moved down to label the model field,
                // where it names the thing it counts; concurrency has nowhere
                // else to go and is the figure that decides whether a queue
                // forms behind this card. `includeSingle` because a card is
                // read beside other cards — see [nodeParallelLabel].
                nodeParallelLabel(node, includeSingle: true),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: AppPalette.textFaint),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        // What the machine is, under what it's called. A hostname says nothing
        // about capability — "Grid-Relay" is the same word for a laptop and for
        // a 192 GB Mac Studio — and this card exists to be read beside other
        // cards, where the chip is the first thing worth comparing.
        //
        // Always drawn, [kUnmeasured] when the node described neither chip nor
        // card, because the dashboard levels its cards by height: a line that
        // came and went would knock every gauge below it out of line with the
        // card beside it, which is the alignment this whole file protects.
        Text(
          hardware.isEmpty ? kUnmeasured : hardware,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: hardware.isEmpty
                ? AppPalette.textFaint
                : AppPalette.textSecondary,
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
          _SegmentedTrack(fraction: metric.fraction!, tone: metric.tone)
        else
          const _DashedTrack(),
      ],
    );
    if (metric.measured) return row;
    return Tooltip(message: _unmeasuredHint, child: row);
  }
}

/// How tall every track is, measured or not, so the rows below one card line up
/// with the rows below the next.
const double _trackHeight = 6;

/// A measured reading: a run of segments, the used ones coloured. All of them
/// grey means a real, measured zero.
///
/// Segments rather than one continuous bar because a reading is compared, not
/// read off: at a glance twelve lit blocks against nineteen is a difference the
/// eye lands on, where two bar ends a few pixels apart is one it has to measure.
///
/// A **fixed count**, not a fixed segment width, so every card divides its own
/// width the same way — two cards side by side are then comparable block for
/// block, which is the whole reason this dashboard levels its rows.
class _SegmentedTrack extends StatelessWidget {
  const _SegmentedTrack({required this.fraction, required this.tone});

  final double fraction;
  final MetricTone tone;

  static const int segments = 24;

  @override
  Widget build(BuildContext context) {
    // Any reading above zero lights at least one block. Rounding alone would
    // leave everything under 2% drawn exactly like a measured zero, and "barely
    // busy" and "doing nothing" are different answers to the question this card
    // is asked.
    final lit = fraction <= 0
        ? 0
        : math.max(1, (fraction * segments).round()).clamp(0, segments);
    return SizedBox(
      height: _trackHeight,
      child: CustomPaint(
        painter: _SegmentPainter(
          lit: lit,
          fill: _toneColor(tone),
          empty: AppCard.inset,
        ),
      ),
    );
  }
}

class _SegmentPainter extends CustomPainter {
  const _SegmentPainter({
    required this.lit,
    required this.fill,
    required this.empty,
  });

  final int lit;
  final Color fill;
  final Color empty;

  static const double _gap = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final width =
        (size.width - _gap * (_SegmentedTrack.segments - 1)) /
        _SegmentedTrack.segments;
    if (width <= 0) return;
    final paint = Paint();
    for (var i = 0; i < _SegmentedTrack.segments; i++) {
      paint.color = i < lit ? fill : empty;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (width + _gap), 0, width, size.height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SegmentPainter old) =>
      old.lit != lit || old.fill != fill || old.empty != empty;
}

/// An unmeasured reading: a hairline where a row of blocks would be.
///
/// The texture is the point, and the texture had to change when the measured
/// track became segmented. It used to be dashes against a solid bar, which read
/// clearly; against twenty-four grey blocks a dashed line is just a coarser row
/// of blocks, and "measured zero" and "never measured" would have collapsed into
/// the same picture — the one confusion this file exists to prevent (see the
/// note at the top of `node_metrics.dart`).
///
/// So it is now the one thing a segmented track can never be: continuous, thin,
/// and centred in the space a track would occupy. It belongs to no scale, cannot
/// be counted, and cannot be mistaken for a quantity of anything.
///
/// Painted rather than built from widgets, because a row of boxes needed a
/// `LayoutBuilder` and **no card may contain one**. The dashboard sizes each row
/// with `IntrinsicHeight` so cards come out level, which asks every child for its
/// intrinsic height; `LayoutBuilder` refuses that question and throws mid-layout,
/// leaving a half-built render tree that the mouse tracker then re-enters. A
/// painter has no such trouble.
class _DashedTrack extends StatelessWidget {
  const _DashedTrack();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _trackHeight,
      child: CustomPaint(painter: _HairlinePainter(color: AppCard.inset)),
    );
  }
}

class _HairlinePainter extends CustomPainter {
  const _HairlinePainter({required this.color});

  final Color color;

  static const double _thickness = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - _thickness) / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, size.width, _thickness),
        const Radius.circular(1),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_HairlinePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The figures that read better as facts than as bars: power, free memory,
/// storage, what the node is serving, and how much it has answered lately. A
/// fixed two-column grid — every card shows all six, so they line up across
/// cards.
class _CardDetails extends StatelessWidget {
  const _CardDetails({required this.node});

  final OverviewNode node;

  @override
  Widget build(BuildContext context) {
    final power = powerMetric(node);
    final storage = storageMetric(node);
    final input = answeredInputMetric(node);
    final cached = answeredCachedMetric(node);
    final tokens = answeredTokensMetric(node);
    final requests = answeredRequestsMetric(node);
    // Both answered figures share one hint, because they are one fact split in
    // two: whichever the pointer lands on, the split behind it is the same.
    final byModel = answeredByModelHint(node);
    final entries = <_Detail>[
      (
        label: power.label,
        value: power.value,
        measured: power.measured,
        hint: '',
      ),
      (
        label: 'Available',
        value: freeMemoryLabel(node),
        measured: freeMemoryLabel(node) != kUnmeasured,
        hint: '',
      ),
      (
        label: storage.label,
        value: storage.value,
        measured: storage.measured,
        hint: '',
      ),
      // Labelled by what the machine serves ("1 chat model", "Image generation")
      // rather than by its engine. The engine label was blank on every `external`
      // node — the app's own generic engine resolves to empty, see
      // [nodeEngineLabel] — which left a model id sitting under nothing at all.
      // The count also has to say what it counts, and up in the header, beside a
      // machine's name, it did not.
      (
        label: nodeRoleSummary(node),
        value: (node.model ?? '').isEmpty ? kUnmeasured : node.model!,
        measured: (node.model ?? '').isNotEmpty,
        hint: '',
      ),
      // The full token split, in the order work happens: what came in, how much
      // of it was already cached, what went out, and how many turns that was.
      // Input is the *fresh* half — cached prefill is a share of input, not a
      // fourth kind, so showing both raw would give the card three figures that
      // sum to more than the machine handled (see [AnsweredTokens]).
      (
        label: input.label,
        value: input.value,
        measured: input.measured,
        hint: byModel,
      ),
      (
        label: cached.label,
        value: cached.value,
        measured: cached.measured,
        hint: byModel,
      ),
      (
        label: tokens.label,
        value: tokens.value,
        measured: tokens.measured,
        hint: byModel,
      ),
      (
        label: requests.label,
        value: requests.value,
        measured: requests.measured,
        hint: byModel,
      ),
    ];
    // A fixed 2-column grid. Not a `Wrap` sized by a `LayoutBuilder`: the
    // dashboard levels each row with `IntrinsicHeight`, which asks every child
    // for its intrinsic height, and `LayoutBuilder` throws rather than answer —
    // see `_DashedTrack`. `Expanded` splits the width without anyone having to
    // measure it.
    return Column(
      children: [
        for (var i = 0; i < entries.length; i += _detailColumns) ...[
          if (i > 0) const SizedBox(height: 12),
          _DetailRow(entries: entries.skip(i).take(_detailColumns).toList()),
        ],
      ],
    );
  }
}

/// One field of the detail grid: what it is, what it reads, whether the node
/// actually reported it, and anything worth adding on hover.
typedef _Detail = ({String label, String value, bool measured, String hint});

/// How many fields sit across the card — the builder slices the entries by it.
const int _detailColumns = 2;

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.entries});

  final List<_Detail> entries;

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
              hint: entries[i].hint,
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
    this.hint = '',
  });

  final String label;
  final String value;
  final bool measured;

  /// What hovering adds, for a figure that summarises something — the per-model
  /// split behind a node's totals. Empty for a field that is already the whole
  /// story, which is most of them.
  final String hint;

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
    // The unmeasured note wins when both could apply: "this machine reports
    // nothing" is the more important thing to say, and a breakdown of a figure
    // that was never measured would have nothing in it anyway.
    if (!measured) return Tooltip(message: _unmeasuredHint, child: field);
    if (hint.isEmpty) return field;
    return Tooltip(message: hint, child: field);
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
            // A gauge, because this figure is the only one on the card without a
            // track under it — the three above are read against a bar, and this
            // one arrives as a bare number at the foot of a card full of them.
            // The mark says "speed" before the eye reaches the unit.
            //
            // Outside the baseline alignment the row imposes: an icon has no
            // alphabetic baseline, so Flutter falls back to its bottom edge and
            // the glyph sinks below the digits it sits beside.
            Padding(
              padding: const EdgeInsets.only(right: 7, bottom: 3),
              child: Icon(
                LucideIcons.gauge,
                size: 17,
                color: measured
                    ? AppPalette.textSecondary
                    : AppPalette.textFaint,
              ),
            ),
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
