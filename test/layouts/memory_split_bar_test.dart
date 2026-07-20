import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/shared/layouts/widgets/memory_split_bar.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

OverviewNode _node({required String name, double? vramGb}) =>
    OverviewNode.fromJson({
      'name': name,
      'online': true,
      'vram_gb': ?vramGb,
    });

Future<void> _pump(WidgetTester tester, List<NodeSlice> slices) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 246, child: MemorySplitBar(slices: slices)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The bar's own slices. Scaffold paints its background with a ColoredBox too,
/// so a bare `find.byType(ColoredBox)` picks up one extra that isn't ours.
Finder get _slices => find.descendant(
  of: find.byType(MemorySplitBar),
  matching: find.byType(ColoredBox),
);

/// Every slice must actually be *painted*, not merely present in the tree.
///
/// The bar shipped once with each slice collapsed to zero height: a `ColoredBox`
/// inside a `Row` gets a loose vertical constraint and takes the minimum, so the
/// widgets existed, the colours were right, and the bar rendered as a strip of
/// empty space. A test asserting the slices exist would have passed. These
/// measure the rendered box instead.
void main() {
  group('MemorySplitBar layout', () {
    testWidgets('every slice fills the bar height', (tester) async {
      final slices = buildMemorySlices([
        _node(name: 'big', vramGb: 382.4),
        _node(name: 'mid', vramGb: 64),
        _node(name: 'small', vramGb: 32),
      ], 478.4);

      await _pump(tester, slices);

      final boxes = _slices;
      expect(boxes, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        expect(
          tester.getSize(boxes.at(i)).height,
          6,
          reason: 'slice $i collapsed — the bar would render as empty space',
        );
      }
    });

    testWidgets('slice widths track their share of the total', (tester) async {
      final slices = buildMemorySlices([
        _node(name: 'big', vramGb: 382.4),
        _node(name: 'mid', vramGb: 64),
        _node(name: 'small', vramGb: 32),
      ], 478.4);

      await _pump(tester, slices);

      final boxes = _slices;
      final widths = [
        for (var i = 0; i < 3; i++) tester.getSize(boxes.at(i)).width,
      ];

      // 80% / 13% / 7% of the bar, so each is clearly wider than the next.
      expect(widths[0], greaterThan(widths[1]));
      expect(widths[1], greaterThan(widths[2]));
      expect(widths[0], greaterThan(150)); // the dominant machine reads as such
    });

    testWidgets('a lone machine takes the whole bar', (tester) async {
      final slices = buildMemorySlices([_node(name: 'solo', vramGb: 64)], 64);

      await _pump(tester, slices);

      final box = _slices;
      expect(box, findsOneWidget);
      expect(tester.getSize(box).height, 6);
      expect(tester.getSize(box).width, 246);
    });

    testWidgets('a sliver of a slice is widened to stay visible', (
      tester,
    ) async {
      // 0.05% of 246px is a tenth of a pixel — it would read as a rendering
      // artefact, so the floor lifts it to something a user can actually see.
      final slices = buildMemorySlices([
        _node(name: 'huge', vramGb: 999.5),
        _node(name: 'tiny', vramGb: 0.5),
      ], 1000);

      await _pump(tester, slices);

      expect(
        tester.getSize(_slices.at(1)).width,
        MemorySplitBar.minSliceWidth,
      );
    });

    testWidgets('widths still fill the bar exactly after a floor lift', (
      tester,
    ) async {
      final slices = buildMemorySlices([
        _node(name: 'huge', vramGb: 999.5),
        _node(name: 'tiny', vramGb: 0.5),
      ], 1000);

      await _pump(tester, slices);

      final total =
          tester.getSize(_slices.at(0)).width +
          tester.getSize(_slices.at(1)).width;
      expect(total, closeTo(246, 0.01));
    });

    testWidgets('the 7% machine from a real grid stays visible', (
      tester,
    ) async {
      // The shipped case: 32 GB against 478.4 is ~17px, already above the
      // floor, so its width is its true share — no lift, no distortion.
      final slices = buildMemorySlices([
        _node(name: 'big', vramGb: 382.4),
        _node(name: 'mid', vramGb: 64),
        _node(name: 'small', vramGb: 32),
      ], 478.4);

      await _pump(tester, slices);

      expect(
        tester.getSize(_slices.at(2)).width,
        greaterThan(MemorySplitBar.minSliceWidth),
      );
    });
  });

  group('buildMemorySlices', () {
    test('assigns a distinct colour per machine, in order', () {
      final slices = buildMemorySlices([
        _node(name: 'a', vramGb: 40),
        _node(name: 'b', vramGb: 30),
        _node(name: 'c', vramGb: 30),
      ], 100);

      expect([for (final s in slices) s.color], [
        kSliceColors[0],
        kSliceColors[1],
        kSliceColors[2],
      ]);
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

    test('shortens shared prefixes in the legend labels', () {
      final slices = buildMemorySlices([
        _node(name: 'MacBooks-MacBook-Pro-6', vramGb: 64),
        _node(name: 'MacBooks-MacBook-Pro-6.local', vramGb: 32),
      ], 96);

      expect([for (final s in slices) s.label], [
        'MacBook-Pro-6',
        'MacBook-Pro-6.local',
      ]);
    });

    test('is empty when nothing reports memory', () {
      expect(buildMemorySlices([_node(name: 'cpu')], 0), isEmpty);
      expect(buildMemorySlices(const [], 100), isEmpty);
    });
  });
}
