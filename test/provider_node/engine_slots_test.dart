import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/engine_slots.dart';
import 'package:grid_app/features/provider_node/logic/serving_engines_provider.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';

ServingEngine _local(String model) => ServingEngine(
  kind: EngineKind.local,
  models: [model],
  apiKind: null,
  endpointUrl: null,
  leaveSelector: model,
);

ServingEngine _connected({
  String model = 'qwen3.5:0.8b',
  String endpoint = 'http://localhost:11434/v1',
}) => ServingEngine(
  kind: EngineKind.external,
  models: [model],
  apiKind: null,
  endpointUrl: endpoint,
  leaveSelector: endpoint,
);

ServingEngine _hosted(List<String> models, {String kind = 'codex'}) =>
    ServingEngine(
      kind: EngineKind.api,
      models: models,
      apiKind: kind,
      endpointUrl: null,
      leaveSelector: kind,
    );

void main() {
  group('this computer shares one engine at a time', () {
    test('nothing serving leaves every way in open', () {
      expect(canAddEngine(const []), isTrue);
    });

    test('a connected server already sharing takes the slot', () {
      expect(canAddEngine([_connected()]), isFalse);
    });

    test('the built-in local engine takes it the same way — the rule is about '
        'the machine, not which kind got there first', () {
      expect(canAddEngine([_local('gemma4-31b.gguf')]), isFalse);
    });

    test('a hosted engine takes it too: it costs this machine nothing to run, '
        'but the machine still offers the grid a single engine', () {
      expect(
        canAddEngine([
          _hosted(['codex:gpt-5.5', 'openai:gpt-5.5']),
        ]),
        isFalse,
      );
    });

    test('an engine with no model named still holds the slot — the rule counts '
        'engines, not what they managed to advertise', () {
      expect(
        canAddEngine([
          ServingEngine(
            kind: EngineKind.external,
            models: const [],
            apiKind: null,
            endpointUrl: 'http://localhost:8080/v1',
            leaveSelector: null,
          ),
        ]),
        isFalse,
      );
    });
  });

  group('a hosted model is never shared twice', () {
    test('the models already live are the ones off the table', () {
      expect(
        apiModelsServed([
          _hosted(['codex:gpt-5.5', 'codex:gpt-5.6-luna']),
        ]),
        {'codex:gpt-5.5', 'codex:gpt-5.6-luna'},
      );
    });

    test('a local model of the same name is not a hosted duplicate — the cloud '
        'block still offers its own', () {
      expect(apiModelsServed([_local('gpt-oss-20b'), _connected()]), isEmpty);
    });

    test('models from several providers all count', () {
      expect(
        apiModelsServed([
          _hosted(['codex:gpt-5.5']),
          _hosted(['openai:gpt-5.5'], kind: 'openai'),
        ]),
        {'codex:gpt-5.5', 'openai:gpt-5.5'},
      );
    });
  });
}
