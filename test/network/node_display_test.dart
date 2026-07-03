import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/node_display.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

OverviewNode _node({
  String engine = 'external',
  String? model,
  List<String> models = const [],
  int? concurrency,
}) =>
    OverviewNode.fromJson({
      'name': 'n',
      'engine': engine,
      if (model != null) 'model': model,
      'models': models,
      if (concurrency != null) 'max_concurrency': concurrency,
      'online': true,
    });

void main() {
  group('nodeEngineLabel', () {
    test('tidies known engines, passes others through', () {
      expect(nodeEngineLabel('comfyui'), 'ComfyUI');
      expect(nodeEngineLabel('external'), 'External');
      expect(nodeEngineLabel(''), 'Engine');
      expect(nodeEngineLabel(null), 'Engine');
      expect(nodeEngineLabel('MLX'), 'MLX');
      expect(nodeEngineLabel('llama.cpp'), 'llama.cpp');
    });
  });

  group('nodeRoleSummary', () {
    test('humanises a comfyui node capabilities', () {
      final node = _node(
        engine: 'comfyui',
        model: 'comfyui:image_generation',
        models: ['comfyui:image_generation', 'comfyui:image_editing'],
      );
      expect(nodeRoleSummary(node), 'Image generation, Image editing');
    });

    test('reads i2v as Video', () {
      expect(nodeRoleSummary(_node(engine: 'comfyui', models: ['comfyui:i2v'])),
          'Video');
    });

    test('counts chat models with correct pluralisation', () {
      expect(
          nodeRoleSummary(_node(models: ['a', 'b', 'c'])), '3 chat models');
      expect(nodeRoleSummary(_node(models: ['only'])), '1 chat model');
    });

    test('falls back to the primary model when the list is empty', () {
      expect(nodeRoleSummary(_node(model: 'solo')), '1 chat model');
    });
  });

  test('nodeIsMedia flags comfyui / capability nodes only', () {
    expect(nodeIsMedia(_node(engine: 'comfyui', models: ['comfyui:i2v'])), isTrue);
    expect(nodeIsMedia(_node(models: ['comfyui:image_generation'])), isTrue);
    expect(nodeIsMedia(_node(engine: 'external', models: ['some/model'])), isFalse);
  });
}
