import '../../../infrastructure/api/models/grid_overview.dart';

/// Pure readings for a node's dashboard card — the relay's raw telemetry turned
/// into the labelled figures and bar fractions the card draws, and nothing else.
/// Kept side-effect free so the card stays dumb and every rule below is unit
/// tested rather than eyeballed in a running app.
///
/// **The whole file is built around one rule: a measurement the node did not
/// report is `null`, and `null` renders as nothing.** Not `0`, not `—%`, not a
/// bar sitting empty at the left edge. A CPU-only box reports no GPU figures at
/// all; a card with no power sensor reports load but no watts; a datacenter card
/// reports everything. Every one of those is a normal, healthy node, and each
/// would be libelled by a zero: an idle-looking GPU, a card at 0°C, a drive with
/// nothing on it. So each reading is independently nullable and the card simply
/// omits the rows it has no numbers for.
///
/// Which readings a platform *can* supply is the provider's business, not this
/// file's — and it is a question worth measuring rather than assuming. An
/// earlier version of this comment asserted that a Mac could never report GPU
/// load or temperature; the IORegistry turned out to publish both to any user,
/// and the provider now sends them.

/// How hard a reading is pushing, for colour only — never for hiding anything.
/// The thresholds are deliberately coarse: this is a glance-level cue about
/// which node is working, not a threshold anybody should alert on.
enum MetricTone { calm, warm, hot }

MetricTone _toneFor(double fraction) {
  if (fraction >= 0.85) return MetricTone.hot;
  if (fraction >= 0.6) return MetricTone.warm;
  return MetricTone.calm;
}

/// One labelled measurement: the row's title, the figure to print, and — when
/// the reading has a meaningful ceiling — how full it is, as 0…1.
///
/// [fraction] is null for a reading with no ceiling to draw a bar against, so a
/// caller can render the same class as either a bar or a plain label row.
class NodeMetric {
  const NodeMetric({
    required this.label,
    required this.value,
    this.fraction,
    this.tone = MetricTone.calm,
  });

  final String label;
  final String value;
  final double? fraction;
  final MetricTone tone;

  @override
  bool operator ==(Object other) =>
      other is NodeMetric &&
      other.label == label &&
      other.value == value &&
      other.fraction == fraction &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(label, value, fraction, tone);
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

/// GPU memory the node brings, and how much of it is busy when it can say:
/// "98.2 / 121.7 GB" with a bar, or a bare "4 GB" with none.
///
/// The bar-less form is what an Intel Mac gets. macOS reports the size of a
/// discrete card's VRAM but never its occupancy, so the total is a real,
/// useful fact — it is the pool a model has to fit into — while the used side
/// is genuinely unknown. Dropping the row entirely would hide the fact the node
/// did report; filling it with a zero would invent the one it did not.
NodeMetric? vramMetric(OverviewNode node) {
  final totalMb = node.vramTotalMb;
  if (totalMb == null || totalMb <= 0) return null;
  final total = totalMb / 1024;
  final usedMb = node.vramUsedMb;
  if (usedMb == null) {
    return NodeMetric(label: 'VRAM', value: '${formatMetricNumber(total)} GB');
  }
  final used = usedMb / 1024;
  final fraction = _fraction(used, total);
  return NodeMetric(
    label: 'VRAM',
    value: '${formatMetricNumber(used)} / ${formatMetricNumber(total)} GB',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// GPU die temperature. The bar runs against a 100 °C ceiling — not a limit the
/// node reported, but the scale every consumer and datacenter card throttles
/// well inside, so a bar near full genuinely means hot.
NodeMetric? temperatureMetric(OverviewNode node) {
  final celsius = node.gpuTempC;
  if (celsius == null) return null;
  final fraction = _fraction(celsius, 100);
  return NodeMetric(
    label: 'Temperature',
    value: '${formatMetricNumber(celsius)}°C',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// How busy the GPU is, 0–100%. A genuine `0%` here is meaningful — the node is
/// online and idle — which is exactly why an unreported reading must not borrow
/// the same rendering.
NodeMetric? usageMetric(OverviewNode node) {
  final pct = node.gpuUtilPct;
  if (pct == null) return null;
  final fraction = (pct / 100).clamp(0.0, 1.0);
  return NodeMetric(
    label: 'Usage',
    value: '${pct.round()}%',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// Power draw, against the card's own cap when it reports one ("42.4W / 120W").
/// A card reporting draw but no cap still gets a row — just no bar to fill.
NodeMetric? powerMetric(OverviewNode node) {
  final draw = node.gpuPowerW;
  if (draw == null) return null;
  final limit = node.gpuPowerLimitW;
  if (limit == null || limit <= 0) {
    return NodeMetric(
      label: 'GPU Power',
      value: '${formatMetricNumber(draw)}W',
    );
  }
  final fraction = _fraction(draw, limit);
  return NodeMetric(
    label: 'GPU Power',
    value: '${formatMetricNumber(draw)}W / ${formatMetricNumber(limit)}W',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// Disk on the volume holding the node's models — the figure that decides
/// whether another model will fit.
NodeMetric? storageMetric(OverviewNode node) {
  final total = node.diskTotalGb;
  final used = node.diskUsedGb;
  if (total == null || used == null || total <= 0) return null;
  final fraction = _fraction(used, total);
  return NodeMetric(
    label: 'Storage',
    value: '${formatMetricNumber(used)} / ${formatMetricNumber(total)} GB',
    fraction: fraction,
    tone: _toneFor(fraction),
  );
}

/// GPU memory still free, e.g. "13.1 GB" — the headroom a new model has to fit
/// into. Null whenever the node did not report both sides of the subtraction.
String? freeVramLabel(OverviewNode node) {
  final freeGb = node.vramFreeGb;
  if (freeGb == null) return null;
  return '${formatMetricNumber(freeGb)} GB';
}

/// Measured decode rate, e.g. "249". Null until the node has actually served a
/// request the provider could time — a node that has answered nothing has no
/// throughput, and any number there would be a benchmark pretending otherwise.
String? throughputLabel(OverviewNode node) {
  final tokS = node.throughputTokS;
  if (tokS == null || tokS <= 0) return null;
  return tokS.round().toString();
}

/// Every reading the card lists at the top, in order, skipping the ones this
/// node has no figure for. An empty list is the honest answer for a node that
/// reports no live telemetry at all — the card then shows its identity and its
/// model, which is all the relay actually knows about it.
List<NodeMetric> nodeBars(OverviewNode node) => [
  ?vramMetric(node),
  ?temperatureMetric(node),
  ?usageMetric(node),
];

/// Why a node's dashboard card is showing no *moving* gauges, phrased for the
/// person reading it rather than as a blank space they have to interpret.
///
/// Keyed on whether anything has a [NodeMetric.fraction] — a bar to fill — not
/// on whether the list is empty. A node reporting a VRAM total and nothing else
/// has a row but no gauge, and it is precisely that node the sentences below are
/// written for: without this it would show a lone figure and leave the missing
/// bars unexplained.
///
/// There is deliberately **no macOS-specific message**. One used to live here,
/// blaming system permissions — and it was simply false: macOS publishes GPU
/// occupancy, load, temperature and power through the IORegistry to any user,
/// which the provider now reads. A Mac reaching this point is not a Mac being
/// restricted, it is a probe that came back empty, and that is what the generic
/// line says. Do not reintroduce a platform excuse without measuring first.
String? missingTelemetryReason(OverviewNode node) {
  if (nodeBars(node).any((metric) => metric.fraction != null)) return null;
  if (node.vramTotalMb == null) {
    return 'This node serves on its processor, so it reports no GPU readings.';
  }
  return 'This node has not reported live readings yet.';
}
