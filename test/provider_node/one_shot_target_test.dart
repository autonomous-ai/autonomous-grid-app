import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/one_shot_target.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/features/provider_node/logic/serving_engines_provider.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';

ServingEngine _engine(EngineKind kind, List<String> models) => ServingEngine(
  kind: kind,
  models: models,
  apiKind: null,
  endpointUrl: null,
  leaveSelector: null,
);

/// `resolveOneShotTarget` takes a `Ref`, so the test asks it the way the app
/// does — from inside a provider — rather than reaching around it.
final _target = Provider<OneShotTarget?>(resolveOneShotTarget);

ProviderContainer _container(List<ServingEngine> serving) {
  final container = ProviderContainer(
    overrides: [
      servingEnginesProvider.overrideWithValue(serving),
      localProviderEndpointProvider.overrideWithValue('http://localhost:8081'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('which model answers a one-shot on this machine', () {
    test('a machine serving TWO models asks for ONE of them, not both joined '
        'into a name no server has', () {
      // `servingModelProvider` is a display label — "qwen3, llama3" reads well
      // in a row and is not a model id. Sent as `model` it was refused, and the
      // caller reported it as "no headline could be written".
      final container = _container([
        _engine(EngineKind.local, ['qwen3', 'llama3']),
      ]);

      final target = container.read(_target);
      expect(target?.model, 'qwen3');
      expect(target?.model, isNot(contains(',')));
    });

    test('the model comes from the LOCAL engine, because the endpoint beside '
        'it is localhost', () {
      // An API engine's model is served by somebody else's machine. Pairing it
      // with http://localhost would ask this computer for a model it does not
      // have.
      final container = _container([
        _engine(EngineKind.api, ['gpt-5.6-sol']),
        _engine(EngineKind.local, ['qwen3']),
      ]);

      expect(container.read(_target)?.model, 'qwen3');
      expect(container.read(_target)?.endpoint, contains('localhost'));
    });

    test('a local engine serving nothing is not a target — the caller falls '
        'through to the grid rather than posting an empty model', () {
      final container = _container([_engine(EngineKind.local, const [])]);
      expect(container.read(localServingModelProvider), isNull);
    });
  });
}
