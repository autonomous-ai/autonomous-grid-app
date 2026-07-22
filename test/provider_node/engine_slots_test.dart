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
      expect(connectBlockedReason(const []), isNull);
    });

    test('a connected server already sharing blocks adding another, and names '
        'what to stop', () {
      final reason = connectBlockedReason([_connected()]);
      expect(reason, isNotNull);
      expect(
        reason,
        contains('qwen3.5:0.8b'),
        reason: 'the user has to know which engine to stop',
      );
    });

    test('the built-in local engine blocks it the same way — the rule is about '
        'the machine, not which kind got there first', () {
      expect(connectBlockedReason([_local('gemma4-31b.gguf')]), isNotNull);
    });

    test('a hosted engine blocks it too: it costs this machine nothing to run, '
        'but the machine still offers the grid a single engine', () {
      final reason = connectBlockedReason([
        _hosted(['codex:gpt-5.5', 'openai:gpt-5.5']),
      ]);
      expect(reason, contains('codex:gpt-5.5'));
    });

    test('an engine with no model named still blocks, described by the server '
        'it points at', () {
      final reason = connectBlockedReason([
        ServingEngine(
          kind: EngineKind.external,
          models: const [],
          apiKind: null,
          endpointUrl: 'http://localhost:8080/v1',
          leaveSelector: null,
        ),
      ]);
      expect(reason, contains('localhost:8080/v1'));
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
