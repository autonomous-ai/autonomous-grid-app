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

  group('nodeIsSubscription', () {
    test('a node with a plan tier is a subscription seat', () {
      expect(nodeIsSubscription(_node(planType: 'pro')), isTrue);
    });

    test('a hardware node — even one reporting VRAM — is not', () {
      expect(nodeIsSubscription(_node()), isFalse);
      expect(nodeIsSubscription(_node(vramGb: 64)), isFalse);
      expect(nodeIsSubscription(_node(planType: '  ')), isFalse);
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

  group('nodePlatformLabel', () {
    test('names the OS and drops the architecture', () {
      // "x86_64" beside a chip name is noise a user can do nothing with.
      expect(nodePlatformLabel('macos-arm64'), 'macOS');
      expect(nodePlatformLabel('macos-x86_64'), 'macOS');
      expect(nodePlatformLabel('linux'), 'Linux');
      expect(nodePlatformLabel('windows'), 'Windows');
    });

    test('null for a provider that reported no platform', () {
      // Rather than a placeholder: an older provider omits the field, and the
      // machine line simply has one part fewer.
      expect(nodePlatformLabel(null), isNull);
      expect(nodePlatformLabel(''), isNull);
      expect(nodePlatformLabel('plan9'), isNull);
    });
  });

  group('nodeMachineLine', () {
    test('prefers the chip over the device, so a Mac is not named twice', () {
      // Apple Silicon providers send both ("Mac Studio" + "M3 Ultra") and the
      // pair says one thing twice; the specific half wins.
      expect(
        nodeMachineLine(
          _machine(
            chip: 'M3 Ultra',
            device: 'Mac Studio',
            platform: 'macos-arm64',
          ),
        ),
        'M3 Ultra · macOS',
      );
    });

    test('falls back to the device when no chip is reported', () {
      // A GPU box sends only the device.
      expect(
        nodeMachineLine(
          _machine(device: 'NVIDIA GeForce RTX 4090 ×2', platform: 'linux'),
        ),
        'NVIDIA GeForce RTX 4090 ×2 · Linux',
      );
    });

    test('names what the machine serves', () {
      expect(
        nodeMachineLine(_machine(chip: 'M3 Ultra', models: ['a', 'b'])),
        'M3 Ultra · 2 chat models',
      );
    });

    test('drops the no-models filler rather than printing it', () {
      // "No models yet" is the empty state of a whole section, not a spec — on
      // one line among several it reads as a fault on a machine that is fine.
      expect(nodeMachineLine(_machine(chip: 'M3 Ultra')), 'M3 Ultra');
    });

    test('empty when the node described neither itself nor its models', () {
      expect(nodeMachineLine(_machine()), '');
    });
  });

  group('nodeActivityLine', () {
    test('leads with the work, then the speed', () {
      // The question the node list is opened to answer is which machine is
      // carrying the grid, so what it has actually done comes before how fast
      // it does it.
      expect(
        nodeActivityLine(
          _machine(
            tokensOut: 1240000,
            requests: 340,
            throughput: 33.6,
            concurrency: 4,
          ),
        ),
        '24h: 1.2M output tokens · 340 requests · ~34 tok/s · 4 parallel',
      );
    });

    test('states the window rather than implying one', () {
      // A cumulative count with no span reads as all-time, which this is not.
      expect(
        nodeActivityLine(
          _machine(tokensOut: 500, requests: 2, windowSeconds: 21600),
        ),
        '6h: 500 output tokens · 2 requests',
      );
    });

    test('keeps a measured zero — an idle machine is not an absent one', () {
      // The relay did the sum and the answer was nothing. That is a real
      // statement about a machine that served nobody today.
      expect(
        nodeActivityLine(_machine(tokensOut: 0, requests: 0)),
        '24h: 0 output tokens · 0 requests',
      );
    });

    test('says nothing about work when the relay computed none', () {
      // An older master sends no `answered` object at all, and a `0` invented
      // there would libel every machine on the grid as idle.
      expect(nodeActivityLine(_machine(chip: 'M3 Ultra')), '');
      expect(
        nodeActivityLine(_machine(chip: 'M3 Ultra', throughput: 33.6)),
        '~34 tok/s',
      );
    });

    test('ignores the GPU and memory readings it no longer carries', () {
      // Both moved to the node dashboard, where a track gives them scale. A
      // single instantaneous sample of a card says little about whether the
      // machine is useful, and Apple Silicon — most of this fleet — reports no
      // utilisation at all, so the line's leading figure used to be blank on
      // most rows.
      expect(
        nodeActivityLine(
          _machine(gpuUtilPct: 42.4, vramTotalMb: 24576, vramUsedMb: 6144),
        ),
        '',
      );
    });

    test('drops a throughput of zero and a concurrency of one', () {
      // Both are "nothing to say" rather than readings: every node runs at least
      // one request at a time, and 0 tok/s is what a node that never answered
      // reports.
      expect(nodeActivityLine(_machine(throughput: 0, concurrency: 1)), '');
    });
  });

  group('answeredByModel', () {
    OverviewNode serving(List<AnsweredModel> byModel, {int window = 86400}) =>
        OverviewNode(
          name: 'n',
          online: true,
          answered: NodeAnswered(
            windowSeconds: window,
            tokensOut: byModel.fold(0, (s, m) => s + m.tokensOut),
            requests: byModel.fold(0, (s, m) => s + m.requests),
            byModel: byModel,
          ),
        );

    test('a model is summed across every machine serving it', () {
      // The relay reports the rollup per node, so the grid-level figure for a
      // model exists nowhere in the payload — it only exists once added up.
      final totals = answeredByModel([
        serving(const [
          AnsweredModel(model: 'glm-4.6', tokensOut: 1000, requests: 10),
          AnsweredModel(model: 'qwen3', tokensOut: 40, requests: 2),
        ]),
        serving(const [
          AnsweredModel(model: 'glm-4.6', tokensOut: 240, requests: 3),
        ]),
      ]);

      expect(totals['glm-4.6']!.tokensOut, 1240);
      expect(totals['glm-4.6']!.requests, 13);
      expect(totals['qwen3']!.tokensOut, 40);
    });

    test('ids that differ only in case are the same model', () {
      // The catalog says `DeepSeek-V4-Flash-0731`; the relay's `public_id` is
      // lowercased at the source. Matching raw would silently find nothing —
      // and silently, because the result is "no figures" rather than an error.
      final totals = answeredByModel([
        serving(const [
          AnsweredModel(
            model: 'deepseek-v4-flash-0731',
            tokensOut: 90,
            requests: 1,
          ),
        ]),
      ]);

      expect(totals[modelKey('DeepSeek-V4-Flash-0731')]!.tokensOut, 90);
    });

    test('a model nobody measured is absent, not zero', () {
      // The caller has to be able to tell "nothing answered on it" from "no
      // relay measured it", and only the missing key carries the second.
      final totals = answeredByModel([
        OverviewNode(name: 'old-relay', online: true),
      ]);

      expect(totals, isEmpty);
    });

    test('the window travels with the sum', () {
      final totals = answeredByModel([
        serving(const [
          AnsweredModel(model: 'glm-4.6', tokensOut: 5, requests: 1),
        ], window: 21600),
      ]);

      expect(totals['glm-4.6']!.windowSeconds, 21600);
    });
  });
}

/// A node described the way the provider describes its host — the hardware and
/// telemetry fields the machine/activity lines read. See `describe_host` in the
/// CLI's `system/hardware.py` for where these values come from.
OverviewNode _machine({
  String? chip,
  String? device,
  String? platform,
  List<String> models = const [],
  double? gpuUtilPct,
  double? vramTotalMb,
  double? vramUsedMb,
  double? throughput,
  int? concurrency,
  int? tokensOut,
  int? requests,
  int windowSeconds = 86400,
}) => OverviewNode.fromJson({
  'name': 'n',
  'chip': ?chip,
  'device': ?device,
  'platform': ?platform,
  'models': models,
  'gpu_util_pct': ?gpuUtilPct,
  'vram_total_mb': ?vramTotalMb,
  'vram_used_mb': ?vramUsedMb,
  'throughput_tok_s': ?throughput,
  'max_concurrency': ?concurrency,
  // Absent unless a count is given, so the default machine is one whose relay
  // computed no rollup at all — the case the line has to stay silent about.
  'answered': tokensOut == null && requests == null
      ? null
      : {
          'window_seconds': windowSeconds,
          'tokens_out': tokensOut ?? 0,
          'requests': requests ?? 0,
        },
  'online': true,
});
