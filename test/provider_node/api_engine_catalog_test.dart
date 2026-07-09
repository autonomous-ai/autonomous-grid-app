import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_catalog.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';

/// Stubs the stored-key read so the provider is offline & deterministic — never
/// touching the real `~/.grid/api_keys.toml`.
class _StubStore extends GridHomeStore {
  const _StubStore(this._kinds);
  final Set<String> _kinds;
  @override
  Set<String> storedApiKinds() => _kinds;
}

const _openaiCatalog = '''
{
  "kind": "openai",
  "last_verified": "2026-07-08",
  "models": [
    {"advertised": "openai:gpt-5.5", "vendor_name": "gpt-5.5",
     "context_window": 1050000, "supports_tools": true, "supports_vision": true,
     "supports_json_mode": true, "supports_structured_outputs": true,
     "notes": "Flagship."},
    {"advertised": "openai:gpt-5.4-nano", "vendor_name": "gpt-5.4-nano",
     "context_window": 400000, "supports_tools": true, "supports_vision": false,
     "supports_json_mode": true, "supports_structured_outputs": true,
     "notes": "Cheapest."}
  ]
}
''';

const _catalogArgs = ['catalog', '--api', 'openai', '--json'];

ProviderContainer _container(GridCliService? cli, {Set<String> stored = const {}}) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(cli),
    gridHomeStoreProvider.overrideWithValue(_StubStore(stored)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('ApiEngineModel.fromJson', () {
    test('parses the catalog model shape', () {
      final model = ApiEngineModel.fromJson(const {
        'advertised': 'openai:gpt-5.5',
        'vendor_name': 'gpt-5.5',
        'context_window': 1050000,
        'supports_tools': true,
        'supports_vision': true,
        'notes': 'Flagship.',
      });
      expect(model.advertised, 'openai:gpt-5.5');
      expect(model.vendorName, 'gpt-5.5');
      expect(model.contextWindow, 1050000);
      expect(model.supportsTools, isTrue);
      expect(model.supportsVision, isTrue);
      expect(model.notes, 'Flagship.');
    });

    test('falls back gracefully on missing optional fields', () {
      final model = ApiEngineModel.fromJson(const {'advertised': 'x:y'});
      expect(model.vendorName, 'x:y');
      expect(model.contextWindow, 0);
      expect(model.supportsTools, isFalse);
      expect(model.notes, '');
    });
  });

  group('apiEnginesProvider', () {
    test('resolves a whitelisted provider with its models and stored-key flag',
        () async {
      final fake = FakeGridCliService()
        ..stubResult(_catalogArgs,
            const CliResult(exitCode: 0, stdout: _openaiCatalog, stderr: ''));
      final container = _container(fake, stored: const {'openai'});

      final engines = await container.read(apiEnginesProvider.future);

      expect(engines, hasLength(1));
      final engine = engines.single;
      expect(engine.provider.kind, 'openai');
      expect(engine.provider.envVar, 'OPENAI_API_KEY');
      expect(engine.hasStoredKey, isTrue);
      expect(engine.lastVerified, '2026-07-08');
      expect(engine.models.map((m) => m.advertised),
          ['openai:gpt-5.5', 'openai:gpt-5.4-nano']);
    });

    test('reports no stored key when the store has none', () async {
      final fake = FakeGridCliService()
        ..stubResult(_catalogArgs,
            const CliResult(exitCode: 0, stdout: _openaiCatalog, stderr: ''));
      final container = _container(fake);

      final engines = await container.read(apiEnginesProvider.future);
      expect(engines.single.hasStoredKey, isFalse);
    });

    test('hides a provider the installed CLI does not whitelist', () async {
      // A non-zero exit is the CLI saying "unknown API kind" — never offer it.
      final fake = FakeGridCliService()
        ..stubResult(_catalogArgs,
            const CliResult(exitCode: 1, stdout: '', stderr: 'Unknown API kind'));
      final container = _container(fake);

      expect(await container.read(apiEnginesProvider.future), isEmpty);
    });

    test('is empty when grid is absent', () async {
      final container = _container(null);
      expect(await container.read(apiEnginesProvider.future), isEmpty);
    });
  });
}
