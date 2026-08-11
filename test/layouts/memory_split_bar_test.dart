import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/shared/layouts/widgets/memory_split_bar.dart';

OverviewNode _node({required String name, double? vramGb, String? planType}) =>
    OverviewNode.fromJson({
      'name': name,
      'online': true,
      'vram_gb': ?vramGb,
      'plan_type': ?planType,
    });

void main() {
  group('buildMemorySlices', () {
    test('assigns a distinct colour per machine, in order', () {
      final slices = buildMemorySlices([
        _node(name: 'a', vramGb: 40),
        _node(name: 'b', vramGb: 30),
        _node(name: 'c', vramGb: 30),
      ], 100);

      expect(
        [for (final s in slices) s.color],
        [kSliceColors[0], kSliceColors[1], kSliceColors[2]],
      );
    });

    test('fractions sum to the whole', () {
      final slices = buildMemorySlices([
        _node(name: 'a', vramGb: 382.4),
        _node(name: 'b', vramGb: 64),
        _node(name: 'c', vramGb: 32),
      ], 478.4);

      final total = slices.fold<double>(0, (sum, s) => sum + s.fraction);
      expect(total, closeTo(1.0, 0.0001));
    });

    test('collapses machines past the fifth into one bucket', () {
      final nodes = [
        for (var i = 0; i < 8; i++) _node(name: 'node-$i', vramGb: 10),
      ];
      final slices = buildMemorySlices(nodes, 80);

      expect(slices.length, kMaxSlices + 1);
      expect(slices.last.label, '+3 more machines');
      expect(slices.last.gb, 30); // the three remaining machines, summed
      expect(slices.last.color, sliceColor(kMaxSlices));
    });

    test('says "machine" when exactly one is collapsed', () {
      final nodes = [
        for (var i = 0; i < 6; i++) _node(name: 'node-$i', vramGb: 10),
      ];
      final slices = buildMemorySlices(nodes, 60);

      expect(slices.last.label, '+1 more machine');
    });

    test('skips machines reporting no VRAM', () {
      final slices = buildMemorySlices([
        _node(name: 'gpu', vramGb: 64),
        _node(name: 'cpu-only'),
      ], 64);

      expect(slices.length, 1);
      expect(slices.single.label, 'gpu');
    });

    test('skips a subscription seat, whatever RAM its machine reports — it '
        'brings a plan, shown as such elsewhere, not a share of this bar', () {
      final slices = buildMemorySlices([
        _node(name: 'gpu', vramGb: 128),
        _node(name: 'codex-seat', vramGb: 64, planType: 'prolite'),
      ], 128);

      expect(slices.length, 1);
      expect(slices.single.label, 'gpu');
    });

    test('shortens shared prefixes in the legend labels', () {
      final slices = buildMemorySlices([
        _node(name: 'MacBooks-MacBook-Pro-6', vramGb: 64),
        _node(name: 'MacBooks-MacBook-Pro-6.local', vramGb: 32),
      ], 96);

      expect(
        [for (final s in slices) s.label],
        ['MacBook-Pro-6', 'MacBook-Pro-6.local'],
      );
    });

    test('is empty when nothing reports memory', () {
      expect(buildMemorySlices([_node(name: 'cpu')], 0), isEmpty);
      expect(buildMemorySlices(const [], 100), isEmpty);
    });
  });
}
