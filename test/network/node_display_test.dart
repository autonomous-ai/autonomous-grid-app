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

    test('names what the machine serves, on its own line', () {
      expect(
        nodeServingLine(_machine(chip: 'M3 Ultra', models: ['a', 'b'])),
        '2 chat models',
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
        '24h: 1.2M output tokens · 340 requests · ~34 tok/s',
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

    test('drops a throughput of zero', () {
      // "Nothing to say" rather than a reading: 0 tok/s is what a node that has
      // never answered reports, and printing it would libel a working machine.
      expect(nodeActivityLine(_machine(throughput: 0)), '');
    });

    test('capacity is not activity, so it is not on this line', () {
      // A static config figure among figures that move, and the one that got
      // ellipsized away on a busy node. It sits with what the node offers.
      expect(nodeActivityLine(_machine(concurrency: 16)), '');
      expect(nodeServingLine(_machine(concurrency: 16)), '16 parallel');
      // One request at a time is every node's floor — nothing to report.
      expect(nodeServingLine(_machine(concurrency: 1)), '');
    });
  });

  group('nodeParallelLabel', () {
    test('says how many requests the machine takes at once', () {
      expect(nodeParallelLabel(_machine(concurrency: 16)), '16 parallel');
    });

    test('the list drops a 1, and a card asks for it back', () {
      // On the panel's 332px row, saying every node's floor out loud is noise.
      // A dashboard card is read *beside* other cards, and among 16-way and
      // 8-way boxes the machine that manages one is the row's whole point.
      expect(nodeParallelLabel(_machine(concurrency: 1)), '');
      expect(
        nodeParallelLabel(_machine(concurrency: 1), includeSingle: true),
        '1 parallel',
      );
    });

    test('a node that reported no concurrency says nothing either way', () {
      // Not "— parallel": this is prose beside a machine's name, not a row in
      // the metrics grid. A machine on an older provider that never sends the
      // field should read as a plain machine, not one with something missing.
      expect(nodeParallelLabel(_machine()), '');
      expect(nodeParallelLabel(_machine(), includeSingle: true), '');
    });

    test('the serving line is built from it, so the two cannot drift', () {
      expect(
        nodeServingLine(
          _machine(models: ['a'], concurrency: 16),
          includeSingleParallel: true,
        ),
        '1 chat model · 16 parallel',
      );
    });
  });

  group('a machine is named the way its owner would name it', () {
    // Built from the relay's own payload shape rather than the Dart constructor: these three
    // fields are produced by a CLI in another repo, and the only thing keeping the two sides
    // agreeing is that the names match. A rename there shows up here as an unnamed machine.
    OverviewNode fromRelay(Map<String, dynamic> node) =>
        OverviewNode.fromJson({'name': 'n', 'online': true, ...node});

    test('Apple Silicon is named by its chip, not its enclosure', () {
      // The GPU is part of the SoC and has no name of its own, so the chip is what a person would
      // say about the machine. The provider sends the model too ("Mac Studio") and the line must
      // not read "Mac Studio · Apple M4 Pro" — that says the same thing twice and costs the row
      // the width its numbers need.
      final node = fromRelay({
        'platform': 'macos-arm64',
        'device': 'Mac Studio',
        'chip': 'Apple M4 Pro',
        'models': ['glm-4.6'],
      });

      expect(nodeMachineLine(node), 'Apple M4 Pro · macOS');
    });

    test('a GPU box is named by its card', () {
      // What decides what the box can run. Its CPU brand is noise beside it, and the provider
      // sends no chip at all for this kind of machine.
      final node = fromRelay({
        'platform': 'linux',
        'device': 'NVIDIA GeForce RTX 4090 ×2',
        'models': ['glm-4.6'],
      });

      expect(nodeMachineLine(node), 'NVIDIA GeForce RTX 4090 ×2 · Linux');
    });

    test('an Intel Mac is named by its card too, not by its chip', () {
      // It has both a CPU and a discrete GPU, and the GPU is the one that matters — so the
      // provider deliberately leaves `chip` null here rather than filling it with the CPU brand.
      final node = fromRelay({
        'platform': 'macos-x86_64',
        'device': 'Radeon Pro 560X',
        'models': ['glm-4.6'],
      });

      expect(nodeMachineLine(node), 'Radeon Pro 560X · macOS');
    });

    test('the name is one phrase, shared by every surface that shows it', () {
      // The node list and the dashboard card both print this. Deriving it twice
      // would let the same machine read "Apple M4 Pro" in one and "Mac Studio"
      // in the other — a mismatch the eye catches instantly and nothing else
      // would flag.
      final apple = fromRelay({
        'platform': 'macos-arm64',
        'device': 'Mac Studio',
        'chip': 'Apple M4 Pro',
      });
      final box = fromRelay({
        'platform': 'linux',
        'device': 'NVIDIA GeForce RTX 4090 ×2',
      });

      expect(nodeHardwareName(apple), 'Apple M4 Pro');
      expect(nodeHardwareName(box), 'NVIDIA GeForce RTX 4090 ×2');
      expect(nodeHardwareName(fromRelay({})), isEmpty);
      // And the list line is built from it, so the two cannot drift.
      expect(
        nodeMachineLine(apple).startsWith(nodeHardwareName(apple)),
        isTrue,
      );
    });

    test('a hardware name is reported verbatim, boilerplate and all', () {
      // An earlier version stripped "(R)" and the core count to make the row
      // fit. That solved the wrong problem — the row was long because it
      // carried four facts — and it made the app the judge of which half of
      // somebody's hardware was worth reading.
      for (final name in const [
        'AMD EPYC 9124 16-Core Processor',
        'Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz',
        'NVIDIA GeForce RTX 4090 ×2',
        'Apple M4 Pro',
      ]) {
        expect(nodeHardwareName(fromRelay({'device': name})), name);
      }
    });

    test('the full name still fits, because it no longer shares its line', () {
      final node = fromRelay({
        'platform': 'linux',
        'device': 'AMD EPYC 9124 16-Core Processor',
        'models': ['a'],
        'max_concurrency': 16,
      });

      expect(nodeMachineLine(node), 'AMD EPYC 9124 16-Core Processor · Linux');
      expect(nodeServingLine(node), '1 chat model · 16 parallel');
    });

    test('the host reads as a handle, not a whole address', () {
      // On a work grid every address shares one domain, so the half after the
      // `@` is the same word on every row: it costs the width that tells the
      // rows apart and adds nothing.
      expect(
        nodeHostHandle(fromRelay({'provider_email': 'design@autonomous.ai'})),
        '@design',
      );
      expect(
        nodeHostHandle(
          fromRelay({'provider_email': 'caonguyenkhanh24@gmail.com'}),
        ),
        '@caonguyenkhanh24',
      );
    });

    test('a node the relay named nobody for carries no handle', () {
      // An older relay sends no `provider_email`, and a lone "@" would be a
      // marker for an owner the grid never named.
      expect(nodeHostHandle(fromRelay({})), isEmpty);
      expect(nodeHostHandle(fromRelay({'provider_email': '  '})), isEmpty);
      expect(
        nodeHostHandle(fromRelay({'provider_email': '@nolocal.com'})),
        isEmpty,
      );
    });

    test('a bare username is shown as it came', () {
      // Some relays fill this with a username rather than an address; dropping
      // it would lose a name the grid does have.
      expect(
        nodeHostHandle(fromRelay({'provider_email': 'scholes'})),
        '@scholes',
      );
    });

    test('a node that described neither is a blank line, not a placeholder', () {
      // Every provider in the field before this shipped. One honest blank beats "Unknown GPU",
      // which a reader would take as something the machine actually reported.
      final node = fromRelay({
        'platform': 'macos-arm64',
        'models': ['glm-4.6'],
      });

      expect(nodeMachineLine(node), 'macOS');
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

    test('a model nobody used today states its zero', () {
      // Hiding the line makes an idle model look like one the app forgot to ask
      // about, and leaves the list saying less the emptier the day was.
      final got = modelAnswered(
        const {},
        'gemma-4-31b-it',
        gridTotal: const NodeAnswered(
          windowSeconds: 86400,
          tokensOut: 500,
          requests: 3,
        ),
      );

      expect(got, isNotNull);
      expect(got!.tokensOut, 0);
      expect(got.requests, 0);
      // Named for the same span as the rows above it.
      expect(got.windowSeconds, 86400);
    });

    test('a grid nothing measured stays silent instead of claiming zeros', () {
      // An older relay computes no rollup at all. Printing "0 requests" against
      // every model on such a grid would report a busy fleet as dead.
      expect(
        modelAnswered(const {}, 'gemma-4-31b-it', gridTotal: null),
        isNull,
      );
    });

    test('a model with its own rows keeps them', () {
      final own = const NodeAnswered(
        windowSeconds: 86400,
        tokensOut: 8000,
        requests: 41,
      );

      expect(
        modelAnswered({'glm-4.6': own}, 'GLM-4.6', gridTotal: own),
        same(own),
      );
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
