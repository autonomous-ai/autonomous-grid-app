import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/node_display.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

OverviewNode _node({
  String engine = 'external',
  String? model,
  List<String> models = const [],
  int? concurrency,
  double? vramGb,
  double? vramTotalMb,
  String? deviceClass,
  String? planType,
}) => OverviewNode.fromJson({
  'name': 'n',
  'engine': engine,
  'model': ?model,
  'models': models,
  'max_concurrency': ?concurrency,
  'vram_gb': ?vramGb,
  'vram_total_mb': ?vramTotalMb,
  'device_class': ?deviceClass,
  'plan_type': ?planType,
  'online': true,
});

void main() {
  group('nodeEngineLabel', () {
    test('tidies known engines, passes others through', () {
      expect(nodeEngineLabel('comfyui'), 'ComfyUI');
      expect(nodeEngineLabel('external'), ''); // dropped from the spec line
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
      expect(
        nodeRoleSummary(_node(engine: 'comfyui', models: ['comfyui:i2v'])),
        'Video',
      );
    });

    test('counts chat models with correct pluralisation', () {
      expect(nodeRoleSummary(_node(models: ['a', 'b', 'c'])), '3 chat models');
      expect(nodeRoleSummary(_node(models: ['only'])), '1 chat model');
    });

    test('falls back to the primary model when the list is empty', () {
      expect(nodeRoleSummary(_node(model: 'solo')), '1 chat model');
    });
  });

  test('nodeIsMedia flags comfyui / capability nodes only', () {
    expect(
      nodeIsMedia(_node(engine: 'comfyui', models: ['comfyui:i2v'])),
      isTrue,
    );
    expect(nodeIsMedia(_node(models: ['comfyui:image_generation'])), isTrue);
    expect(
      nodeIsMedia(_node(engine: 'external', models: ['some/model'])),
      isFalse,
    );
  });

  group('mediaCapabilityLabel', () {
    test('labels comfyui media ids, null for a text model', () {
      expect(
        mediaCapabilityLabel('comfyui:image_generation'),
        'Image generation',
      );
      expect(mediaCapabilityLabel('comfyui:image_editing'), 'Image editing');
      expect(mediaCapabilityLabel('comfyui:i2v'), 'Video');
      expect(mediaCapabilityLabel('qwen3-coder'), isNull);
    });
  });

  group('isRealChatModel', () {
    test('a normal text model is a real, answerable model', () {
      expect(isRealChatModel('qwen3-coder'), isTrue);
    });

    test('the virtual auto router is not a real model — a grid whose only '
        'model is auto has nothing to route to', () {
      expect(isRealChatModel('auto'), isFalse);
      expect(isRealChatModel(kAutoModelId), isFalse);
    });

    test('a leaked media capability is not a chat model', () {
      expect(isRealChatModel('comfyui:image_generation'), isFalse);
      expect(isRealChatModel('comfyui:i2v'), isFalse);
    });
  });

  group('answerableModels', () {
    test('a grid whose only model is the auto router counts as having none — '
        'the router has nothing behind it to answer with', () {
      expect(answerableModels([kAutoModelId]), isEmpty);
    });

    test('the router is kept once real models exist, because then it routes '
        'to one of them', () {
      expect(answerableModels([kAutoModelId, 'qwen3-coder']), [
        kAutoModelId,
        'qwen3-coder',
      ]);
    });

    test('a grid serving nothing at all stays empty', () {
      expect(answerableModels(const []), isEmpty);
    });

    test('a normal model list passes through untouched', () {
      expect(answerableModels(['qwen3-coder']), ['qwen3-coder']);
    });
  });

  test('isVideoCapability is true only for the i2v capability', () {
    expect(isVideoCapability('comfyui:i2v'), isTrue);
    expect(isVideoCapability('comfyui:image_generation'), isFalse);
    expect(isVideoCapability('qwen3-coder'), isFalse);
  });

  group('nodeVramLabel', () {
    test('formats vram_gb, dropping a trailing .0', () {
      expect(nodeVramLabel(_node(vramGb: 48.0)), '48 GB VRAM');
      expect(nodeVramLabel(_node(vramGb: 47.5)), '47.5 GB VRAM');
    });

    test('falls back to vram_total_mb when vram_gb is absent', () {
      expect(nodeVramLabel(_node(vramTotalMb: 4096.0)), '4 GB VRAM');
    });

    test('null when the node reports no usable VRAM', () {
      expect(nodeVramLabel(_node()), isNull);
      expect(nodeVramLabel(_node(vramGb: 0.0)), isNull);
    });
  });

  group('nodePlanLabel', () {
    test('capitalises the tier into a "… plan" label', () {
      expect(nodePlanLabel(_node(planType: 'free')), 'Free plan');
      expect(nodePlanLabel(_node(planType: 'plus')), 'Plus plan');
      expect(nodePlanLabel(_node(planType: 'pro')), 'Pro plan');
    });

    test('null for a node that carries no plan', () {
      expect(nodePlanLabel(_node()), isNull);
      expect(nodePlanLabel(_node(planType: '  ')), isNull);
    });
  });

  group('nodeSpecLine', () {
    test('joins engine and device class', () {
      // The Art grid's own node: reports an engine and a GPU, but no VRAM.
      expect(
        nodeSpecLine(_node(engine: 'doggi', deviceClass: 'gpu')),
        'doggi · GPU',
      );
    });

    test('appends the subscription tier when the node carries one', () {
      // A codex seat node (no VRAM) reads as its tier, not an anonymous machine.
      expect(
        nodeSpecLine(_node(engine: 'codex', planType: 'free')),
        'codex · Free plan',
      );
    });

    test('drops the generic external engine, keeping the device', () {
      // `external` is the app's own engine id and means nothing to a user, so
      // the line falls back to what the hardware is.
      expect(
        nodeSpecLine(_node(engine: 'external', deviceClass: 'gpu')),
        'GPU',
      );
    });

    test('drops the "Engine" placeholder when no engine is reported', () {
      // nodeEngineLabel turns an empty engine into "Engine", which is a label,
      // not information — it must not reach this line.
      expect(nodeSpecLine(_node(engine: '', deviceClass: 'cpu')), 'CPU');
    });

    test('engine alone when no device class is reported', () {
      expect(nodeSpecLine(_node(engine: 'codex')), 'codex');
    });

    test('empty when the node reports neither', () {
      expect(nodeSpecLine(_node(engine: 'external')), '');
      expect(nodeSpecLine(_node(engine: '')), '');
    });
  });
}
