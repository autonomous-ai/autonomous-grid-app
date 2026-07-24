import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

OverviewNode _node({
  required String engine,
  bool online = true,
  List<String> models = const [],
}) => OverviewNode(
  name: 'n-$engine',
  online: online,
  engine: engine,
  models: models,
);

/// A grid lists a model running on a 4090 in the room and a model relayed to
/// OpenAI under names that give nothing away, so "where does this answer come
/// from?" can only be read off the node serving it. `/models` reports every entry
/// identically — these pin the reading that replaces it.
void main() {
  group('hostingForEngine', () {
    test('an engine that answers from its own machine is on the grid', () {
      expect(hostingForEngine('llama.cpp'), ModelHosting.onGrid);
      expect(hostingForEngine('ollama'), ModelHosting.onGrid);
      // `grid join --at <url>` — someone's own server is still their machine.
      expect(hostingForEngine('external'), ModelHosting.onGrid);
    });

    test('a hosted provider the CLI whitelists is a cloud relay', () {
      expect(hostingForEngine('codex'), ModelHosting.cloud);
      expect(hostingForEngine('openai'), ModelHosting.cloud);
      expect(hostingForEngine('CODEX'), ModelHosting.cloud);
    });

    test('an engine we do not recognise stays unknown rather than guessing — a '
        'wrong "runs on the grid" is a privacy claim we cannot back', () {
      expect(hostingForEngine('some-new-engine'), ModelHosting.unknown);
      expect(hostingForEngine(null), ModelHosting.unknown);
      expect(hostingForEngine('  '), ModelHosting.unknown);
    });
  });

  group('hostingByModel', () {
    test('reads each model off the node serving it', () {
      final byModel = hostingByModel([
        _node(engine: 'codex', models: ['codex:gpt-5.5', 'codex:gpt-5.4-mini']),
        _node(engine: 'external', models: ['laguna-s-2.1']),
      ]);

      expect(byModel['codex:gpt-5.5'], ModelHosting.cloud);
      expect(byModel['codex:gpt-5.4-mini'], ModelHosting.cloud);
      expect(byModel['laguna-s-2.1'], ModelHosting.onGrid);
    });

    test('an offline node claims nothing — it is not answering anything', () {
      final byModel = hostingByModel([
        _node(engine: 'llama.cpp', online: false, models: ['qwen']),
      ]);
      expect(byModel, isEmpty);
    });

    test('a model served both from a machine and from a cloud relay reads as '
        'unknown — which one answers is the relay\'s choice, not ours', () {
      final byModel = hostingByModel([
        _node(engine: 'llama.cpp', models: ['shared']),
        _node(engine: 'openai', models: ['shared']),
      ]);
      expect(byModel['shared'], ModelHosting.unknown);
    });
  });

  group('playgroundOptionsFrom', () {
    test('carries each model\'s hosting through to the row', () {
      final options = playgroundOptionsFrom(
        const [OverviewModel(id: 'codex:gpt-5.5'), OverviewModel(id: 'qwen')],
        const [],
        hosting: const {
          'codex:gpt-5.5': ModelHosting.cloud,
          'qwen': ModelHosting.onGrid,
        },
      );

      expect(
        {for (final o in options) o.id: o.hosting},
        {'codex:gpt-5.5': ModelHosting.cloud, 'qwen': ModelHosting.onGrid},
      );
    });

    test('the auto router is neither — it has not picked yet', () {
      final options = playgroundOptionsFrom(const [
        OverviewModel(id: 'auto'),
        OverviewModel(id: 'qwen'),
      ], const []);

      expect(options.first.hosting, ModelHosting.routed);
      // And a model nothing on the grid claims makes no claim of its own.
      expect(options.last.hosting, ModelHosting.unknown);
    });
  });
}
