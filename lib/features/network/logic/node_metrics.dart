/// Pure readings for a node's dashboard card — the relay's raw telemetry turned
/// into the labelled figures and bar fractions the card draws, and nothing else.
/// Kept side-effect free so the card stays dumb and every rule below is unit
/// tested rather than eyeballed in a running app.
///
/// **Every card shows every row, whether or not the machine reported it.** Rows
/// that come and go made two machines side by side impossible to compare — the
/// eye has to re-read the labels on each card before it can read the numbers —
/// and left cards of different heights. So a reading the node never sent still
/// gets its row, printed as [kUnmeasured] with a track the card draws dashed.
///
/// That places the whole weight of one distinction on the rendering: **a value
/// that was measured as zero and a value that was never measured must not look
/// alike.** An idle GPU genuinely at `0%` and a GPU that reports no utilisation
/// at all are different facts, and a node libelled by the wrong one looks dead.
/// Two things separate them, and both are load-bearing: the figure reads `0%`
/// against [kUnmeasured], and the bar is a solid empty track against a dashed
/// one. Neither alone is enough — do not drop one as redundant.
library;

import '../../../infrastructure/api/models/grid_overview.dart';

/// Printed in place of a figure the node did not report. An em dash, not `0`,
/// `N/A`, or an empty string: it reads as "nothing here" at a glance without
/// looking like a measurement or like a bug.
const String kUnmeasured = '—';

/// How hard a reading is pushing, for colour only — never for hiding anything.
/// The thresholds are deliberately coarse: this is a glance-level cue about
/// which node is working, not a threshold anybody should alert on.
enum MetricTone { calm, warm, hot }

MetricTone _toneFor(double fraction) {
  if (fraction >= 0.85) return MetricTone.hot;
  if (fraction >= 0.6) return MetricTone.warm;
  return MetricTone.calm;
}

/// One labelled row on a card: its title, the figure to print, and — when the
/// reading has both a value and a ceiling — how full it is, as 0…1.
///
/// [measured] is false when the node reported nothing for this row. The card
/// then prints [value] (already [kUnmeasured]) and draws its track dashed, so
/// "not reported" never reads as a real reading of zero.
class NodeMetric {
  const NodeMetric({
    required this.label,
    required this.value,
    this.fraction,
    this.tone = MetricTone.calm,
    this.measured = true,
  });

  /// A row the node said nothing about.
  const NodeMetric.unmeasured({required this.label, this.value = kUnmeasured})
    : fraction = null,
      tone = MetricTone.calm,
      measured = false;

  final String label;
  final String value;
  final double? fraction;
  final MetricTone tone;
  final bool measured;

  @override
  bool operator ==(Object other) =>
      other is NodeMetric &&
      other.label == label &&
      other.value == value &&
      other.fraction == fraction &&
      other.tone == tone &&
      other.measured == measured;

  @override
  int get hashCode => Object.hash(label, value, fraction, tone, measured);
}

/// A figure with at most one decimal, and no trailing `.0` — so a drive reads
/// "3755 GB" rather than "3755.0 GB" while VRAM keeps its "121.7".
String formatMetricNumber(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// Clamped so a card can never draw a bar past its track: a provider reporting
/// 105% utilisation is a provider bug, and the card should look pinned rather
/// than overflow its own layout.
double _fraction(double used, double total) =>
    total <= 0 ? 0 : (used / total).clamp(0.0, 1.0);

/// What a node's GPU memory should be *called* on its card.
///
/// An Apple Silicon machine has no VRAM: the GPU shares one unified pool with
/// the CPU, which is why the provider advertises `hw.memsize` as its memory in
/// the first place. Calling that "VRAM" invites the reader to look for a
/// graphics card that does not exist, and to misread 64 GB as dedicated when it
/// is the whole machine's memory.
String memoryLabel(OverviewNode node) =>
    (node.platform ?? '').toLowerCase().startsWith('macos-arm')
    ? 'RAM'
    : 'VRAM';

/// Memory in use against the node's total — "377.1 / 382.4 GB", or a partial
/// "— / 64 GB" when the machine reports a size but not its occupancy.
NodeMetric memoryMetric(OverviewNode node) {
  final label = memoryLabel(node);
  final totalMb = node.vramTotalMb;
  final usedMb = node.vramUsedMb;
  if (totalMb == null || totalMb <= 0) {
    return NodeMetric.unmeasured(
      label: label,
      value: '$kUnmeasured / $kUnmeasured',
    );
  }
  final total = totalMb / 1024;
  if (usedMb == null) {
    // The total is a real fact worth printing — it is the pool a model has to
    // fit into — so only the missing half degrades.
    return NodeMetric.unmeasured(
      label: label,
      value: '$kUnmeasured / ${formatMetricNumber(total)} GB',
    );
  }
  final used = usedMb / 1024;
  final fraction = _fraction(used, total);
  return NodeMetric(
    label: label,
    value: '${formatMetricNumber(used)} / ${formatMetricNumber(total)} GB',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// GPU die temperature. The bar runs against a 100 °C ceiling — not a limit the
/// node reported, but the scale every consumer and datacenter card throttles
/// well inside, so a bar near full genuinely means hot.
NodeMetric temperatureMetric(OverviewNode node) {
  final celsius = node.gpuTempC;
  if (celsius == null) return const NodeMetric.unmeasured(label: 'Temperature');
  final fraction = _fraction(celsius, 100);
  return NodeMetric(
    label: 'Temperature',
    value: '${formatMetricNumber(celsius)}°C',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// How busy the GPU is, 0–100%. A genuine `0%` here is meaningful — the node is
/// online and idle — which is why it must not render like an absent reading.
NodeMetric usageMetric(OverviewNode node) {
  final pct = node.gpuUtilPct;
  if (pct == null) return const NodeMetric.unmeasured(label: 'Usage');
  final fraction = (pct / 100).clamp(0.0, 1.0);
  return NodeMetric(
    label: 'Usage',
    value: '${pct.round()}%',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// Power draw against the card's own cap — "894.8W / 2400W". A card reporting
/// draw but no cap shows "894.8W / —": the draw is real, the ceiling is not
/// something macOS or that driver publishes, and inventing one from a spec sheet
/// would draw a bar whose denominator nothing measured.
NodeMetric powerMetric(OverviewNode node) {
  final draw = node.gpuPowerW;
  final limit = node.gpuPowerLimitW;
  if (draw == null) {
    return const NodeMetric.unmeasured(
      label: 'GPU Power',
      value: '$kUnmeasured / $kUnmeasured',
    );
  }
  final drawText = '${formatMetricNumber(draw)}W';
  if (limit == null || limit <= 0) {
    return NodeMetric.unmeasured(
      label: 'GPU Power',
      value: '$drawText / $kUnmeasured',
    );
  }
  final fraction = _fraction(draw, limit);
  return NodeMetric(
    label: 'GPU Power',
    value: '$drawText / ${formatMetricNumber(limit)}W',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// Disk on the volume holding the node's models — the figure that decides
/// whether another model will fit.
NodeMetric storageMetric(OverviewNode node) {
  final total = node.diskTotalGb;
  final used = node.diskUsedGb;
  if (total == null || used == null || total <= 0) {
    return const NodeMetric.unmeasured(
      label: 'Storage',
      value: '$kUnmeasured / $kUnmeasured',
    );
  }
  final fraction = _fraction(used, total);
  return NodeMetric(
    label: 'Storage',
    value: '${formatMetricNumber(used)} / ${formatMetricNumber(total)} GB',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// Memory still free, e.g. "13.1 GB" — the headroom a new model has to fit into,
/// or [kUnmeasured] when the node did not report both sides of the subtraction.
String freeMemoryLabel(OverviewNode node) {
  final freeGb = node.vramFreeGb;
  if (freeGb == null) return kUnmeasured;
  return '${formatMetricNumber(freeGb)} GB';
}

/// Measured decode rate, e.g. "249", or [kUnmeasured] until the node has served
/// a request the provider could time. A node that has answered nothing has no
/// throughput, and any number there would be a benchmark pretending otherwise.
String throughputLabel(OverviewNode node) {
  final tokS = node.throughputTokS;
  if (tokS == null || tokS <= 0) return kUnmeasured;
  return tokS.round().toString();
}

/// The three bars every card draws, in order. Always three — see the note at the
/// top of this file on why a row is never dropped.
List<NodeMetric> nodeBars(OverviewNode node) => [
  memoryMetric(node),
  temperatureMetric(node),
  usageMetric(node),
];
