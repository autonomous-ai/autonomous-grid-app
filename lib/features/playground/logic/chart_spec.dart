import 'dart:convert';

/// The two shapes a chart in a reply can take.
enum ChartKind {
  /// Comparing things side by side.
  bar,

  /// A value moving over a sequence.
  line,
}

/// One named run of numbers in a chart.
class ChartSeries {
  const ChartSeries({required this.name, required this.values});

  /// Shown in the legend. Empty on a single-series chart, which needs none.
  final String name;
  final List<double> values;
}

/// A chart the assistant asked for, parsed out of a ```chart fence.
///
/// The assistant can already produce a table; what it could not do was show a
/// shape. Twelve rows of numbers is the answer the app made the user read
/// because the transcript had no way to draw it — so a fenced block of plain
/// JSON becomes a real chart, and stays a plain code block when it isn't one.
///
/// The format is deliberately small (see `grid-chart`, the skill that teaches
/// it): a type, labels along the bottom, and one or more series of numbers.
class ChartSpec {
  const ChartSpec({
    required this.kind,
    required this.labels,
    required this.series,
    this.title,
  });

  final ChartKind kind;

  /// One label per point along the bottom.
  final List<String> labels;

  /// At least one series, each already trimmed to [labels]' length.
  final List<ChartSeries> series;

  /// Optional heading above the chart.
  final String? title;

  /// The largest and smallest value across every series — what the axis has to
  /// cover. Zero is always included, so a bar's height means what it looks like.
  double get maxValue {
    var max = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v > max) max = v;
      }
    }
    return max;
  }

  double get minValue {
    var min = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v < min) min = v;
      }
    }
    return min;
  }

  /// Parse a ```chart block, or null when it isn't one the app can draw.
  ///
  /// Null rather than a thrown error or a half-drawn chart: the caller falls
  /// back to showing the block as code, which is honest about what arrived
  /// instead of replacing the assistant's output with "invalid chart".
  static ChartSpec? parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final labels = [for (final label in _list(decoded['labels'])) '$label'];
    if (labels.isEmpty) return null;

    final series = _seriesOf(decoded, labels.length);
    if (series.isEmpty) return null;

    return ChartSpec(
      kind: decoded['type'] == 'line' ? ChartKind.line : ChartKind.bar,
      labels: List.unmodifiable(labels),
      series: List.unmodifiable(series),
      title: switch (decoded['title']) {
        final String t when t.trim().isNotEmpty => t.trim(),
        _ => null,
      },
    );
  }

  /// The series, from either shape: several named runs, or the one-series
  /// shorthand `"values": [...]` with no name to put in a legend.
  static List<ChartSeries> _seriesOf(Map<Object?, Object?> json, int points) {
    final raw = _list(json['series']);
    if (raw.isEmpty) {
      final values = _numbers(json['values'], points);
      return values.isEmpty
          ? const []
          : [ChartSeries(name: '', values: values)];
    }
    return [
      for (final entry in raw)
        if (entry is Map)
          if (_numbers(entry['values'], points) case final values
              when values.isNotEmpty)
            ChartSeries(name: '${entry['name'] ?? ''}', values: values),
    ];
  }

  /// The numbers of one series, cut to [points].
  ///
  /// A series longer than the labels is trimmed and a shorter one is left short
  /// — never padded with zeros, which would draw data nobody sent.
  static List<double> _numbers(Object? raw, int points) {
    final values = <double>[];
    for (final value in _list(raw)) {
      if (values.length == points) break;
      final number = value is num
          ? value.toDouble()
          : double.tryParse('$value');
      if (number == null || !number.isFinite) return const [];
      values.add(number);
    }
    return values;
  }

  static List<Object?> _list(Object? raw) => raw is List ? raw : const [];
}
