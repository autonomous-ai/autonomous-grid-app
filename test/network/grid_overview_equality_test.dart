import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

GridOverview _parse({
  bool online = true,
  double vramGb = 16,
  List<String> models = const ['llama'],
}) => GridOverview.fromJson({
  'grid': {'state': 'active'},
  'stats': {'models': models.length, 'nodes': 1, 'uptime_pct': 99.5},
  'models': [
    for (final id in models)
      {'id': id, 'modality': 'text', 'context_length': 8192},
  ],
  'nodes': [
    {
      'name': 'mac',
      'online': online,
      'vram_gb': vramGb,
      'models': models,
      'engine': 'llama.cpp',
    },
  ],
});

/// The overview is re-fetched on a timer, so "did this snapshot change?" is
/// asked every cadence. These pin that the answer comes from the figures, not
/// from the fact that parsing produced a new object — the difference between a
/// quiet app and one that recomputes and repaints every grid-derived screen on
/// each poll.
void main() {
  group('GridOverview equality', () {
    test('two snapshots of an unchanged grid are equal', () {
      expect(_parse(), _parse());
      expect(_parse().hashCode, _parse().hashCode);
    });

    test('a machine going offline makes it a different snapshot', () {
      expect(_parse(online: false), isNot(_parse()));
    });

    test('a figure moving makes it a different snapshot', () {
      expect(_parse(vramGb: 8), isNot(_parse()));
    });

    test('the models a grid serves are compared by content, not identity', () {
      // Two parses build two separate lists of separate OverviewModel objects;
      // only value equality all the way down can call them the same.
      expect(
        _parse(models: ['llama', 'qwen']),
        _parse(models: const ['llama', 'qwen']),
      );
      expect(_parse(models: ['llama']), isNot(_parse(models: ['qwen'])));
    });
  });
}
