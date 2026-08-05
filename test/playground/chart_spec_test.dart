import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chart_spec.dart';

void main() {
  group('a chart the assistant asked for', () {
    test('the single-series shorthand is enough to draw', () {
      final spec = ChartSpec.parse('''
{"title": "Requests", "labels": ["Mon", "Tue"], "values": [3, 5]}
''');
      expect(spec?.kind, ChartKind.bar);
      expect(spec?.title, 'Requests');
      expect(spec?.labels, ['Mon', 'Tue']);
      expect(spec?.series.single.values, [3.0, 5.0]);
      expect(spec?.series.single.name, isEmpty);
    });

    test('several named series come back in order, for the legend', () {
      final spec = ChartSpec.parse('''
{"type": "line", "labels": ["a", "b"],
 "series": [{"name": "p50", "values": [1, 2]},
            {"name": "p95", "values": [4, 5]}]}
''');
      expect(spec?.kind, ChartKind.line);
      expect([for (final s in spec!.series) s.name], ['p50', 'p95']);
    });

    test('the axis always covers zero, so a bar\'s height means what it looks '
        'like', () {
      final spec = ChartSpec.parse('{"labels": ["a"], "values": [40]}');
      expect(spec?.minValue, 0);
      expect(spec?.maxValue, 40);
    });

    test('negative numbers push the floor down rather than being clipped', () {
      final spec = ChartSpec.parse('{"labels": ["a","b"], "values": [-8, 4]}');
      expect(spec?.minValue, -8);
      expect(spec?.maxValue, 4);
    });
  });

  group('a block that is not a chart stays a code block', () {
    test('nothing to draw comes back null rather than half a chart', () {
      expect(ChartSpec.parse('not json at all'), isNull);
      expect(ChartSpec.parse('[1, 2, 3]'), isNull);
      expect(ChartSpec.parse('{"labels": [], "values": [1]}'), isNull);
      expect(ChartSpec.parse('{"labels": ["a"]}'), isNull);
    });

    test('a value that is not a number sinks the series — "1.2k" drawn as 1.2 '
        'would be a chart of the wrong thing', () {
      expect(
        ChartSpec.parse('{"labels": ["a","b"], "values": [1, "1.2k"]}'),
        isNull,
      );
      expect(ChartSpec.parse('{"labels": ["a"], "values": [null]}'), isNull);
    });
  });

  group('lining values up with labels', () {
    test('a series longer than the labels is cut, not squeezed in', () {
      final spec = ChartSpec.parse(
        '{"labels": ["a","b"], "values": [1,2,3,4]}',
      );
      expect(spec?.series.single.values, [1.0, 2.0]);
    });

    test('a shorter one is left short — padding with zeros would draw data '
        'nobody sent', () {
      final spec = ChartSpec.parse('{"labels": ["a","b","c"], "values": [1]}');
      expect(spec?.series.single.values, [1.0]);
    });
  });
}
