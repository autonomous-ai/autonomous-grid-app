import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

void main() {
  group('distinctOverviewModels', () {
    test('keeps a single row for a model that has no duplicates', () {
      const m = OverviewModel(id: 'qwen', vision: true);
      expect(distinctOverviewModels([m]), [m]);
    });

    test('collapses duplicate ids to one entry per model', () {
      final result = distinctOverviewModels([
        const OverviewModel(id: 'DeepSeek-V4-Flash-0731'),
        const OverviewModel(id: 'DeepSeek-V4-Flash-0731'),
        const OverviewModel(id: 'minimax/minimax-m3'),
        const OverviewModel(id: 'qwen/qwen3.6-27b'),
      ]);
      expect(result.map((m) => m.id), [
        'DeepSeek-V4-Flash-0731',
        'minimax/minimax-m3',
        'qwen/qwen3.6-27b',
      ]);
    });

    test('prefers the row with pricing over a bare-id twin, so the tile '
        'keeps its label and price', () {
      const bare = OverviewModel(id: 'deepseek');
      const priced = OverviewModel(
        id: 'deepseek',
        contextLength: 200000,
        pricing: ModelPricing(unit: 'token', inputPer1m: 0.08),
      );
      final result = distinctOverviewModels([bare, priced]);
      expect(result.single, priced);
    });

    test('a richer twin wins regardless of list order', () {
      const rich = OverviewModel(
        id: 'deepseek',
        contextLength: 204800,
        vision: false,
      );
      const bare = OverviewModel(id: 'deepseek');
      final result = distinctOverviewModels([rich, bare]);
      expect(result.single, rich);
    });
  });
}
