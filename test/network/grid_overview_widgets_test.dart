import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/presentation/grid_overview_widgets.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

Future<void> _pumpStatsBar(
  WidgetTester tester, {
  required GridStats stats,
  required List<OverviewModel> resolved,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [gridModelsProvider.overrideWith((ref) => resolved)],
    child: MaterialApp(
      home: Scaffold(body: StatsBar(stats: stats)),
    ),
  ),
);

void main() {
  group('StatsBar', () {
    testWidgets('prefers the resolved model count over stats.models', (
      tester,
    ) async {
      await _pumpStatsBar(
        tester,
        stats: const GridStats(models: 0, nodes: 3, uptimePct: 99.9),
        resolved: const [
          OverviewModel(id: 'a'),
          OverviewModel(id: 'b'),
        ],
      );

      expect(find.text('MODELS'), findsOneWidget);
      expect(
        find.text('2'),
        findsOneWidget,
      ); // resolved wins over stats.models=0
      expect(find.text('3'), findsOneWidget); // nodes
      expect(find.text('99.9%'), findsOneWidget);
    });

    testWidgets('falls back to stats.models when nothing is resolved', (
      tester,
    ) async {
      await _pumpStatsBar(
        tester,
        stats: const GridStats(models: 5, nodes: 1),
        resolved: const [],
      );

      expect(find.text('5'), findsOneWidget); // stats.models fallback
      expect(find.text('—'), findsOneWidget); // null uptime → em dash
    });
  });
}
