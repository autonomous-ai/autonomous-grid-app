import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/provider_node/logic/auto_serve_controller.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart'
    show GridProcess;
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/auto_serve_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// Records every long-running `grid` call — a join is one — so a test can say
/// whether the app started an engine at all, which is the whole question here.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> starts = [];

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) {
    starts.add(List.unmodifiable(args));
    return super.start(args, environment: environment);
  }
}

/// A computer with no engine records at all, so the launch check never reads
/// the real `~/.grid` — where a grid that happened to be serving would flip the
/// result under the test.
class _NoEngineRuns extends GridHomeStore {
  const _NoEngineRuns();

  @override
  List<EngineRunRecord> listEngineRuns(String gridId) => const [];
}

NetworkCredential _grid(String id) => NetworkCredential(
  networkId: id,
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/$id',
  accessToken: 'tok',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: const [],
  scopes: const [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

class _PickedNetwork extends SelectedNetwork {
  _PickedNetwork(this.grid);
  final NetworkCredential? grid;

  @override
  NetworkCredential? build() => grid;
}

LocalModel _model(String name) =>
    LocalModel(name: name, path: '/tmp/$name', sizeBytes: 1);

late Directory _tmp;

ProviderContainer _container({
  required AutoServePrefs prefs,
  required _RecordingCli cli,
  List<LocalModel> models = const [],
  NetworkCredential? network,
  bool engineInstalled = true,
}) {
  final file = File(
    '${_tmp.path}/auto_serve_${DateTime.now().microsecondsSinceEpoch}.json',
  );
  final store = AutoServeStore(file: file);
  store.save(prefs);

  final container = ProviderContainer(
    overrides: [
      autoServeStoreProvider.overrideWithValue(store),
      gridCliServiceProvider.overrideWithValue(cli),
      gridHomeStoreProvider.overrideWithValue(const _NoEngineRuns()),
      selectedNetworkProvider.overrideWith(() => _PickedNetwork(network)),
      localModelsProvider.overrideWithValue(models),
      engineStatusProvider.overrideWithValue(
        engineInstalled
            ? const EngineStatus(llamaInstalled: true, llamaPath: '/bin/llama')
            : EngineStatus.notInstalled,
      ),
      // Never bind a real socket in a test.
      freePortFinderProvider.overrideWithValue(() async => 51234),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

bool _joined(_RecordingCli cli) =>
    cli.starts.any((args) => args.isNotEmpty && args.first == 'join');

void main() {
  setUpAll(() => _tmp = Directory.systemTemp.createTempSync('auto_serve'));
  tearDownAll(() => _tmp.deleteSync(recursive: true));

  const armed = AutoServePrefs(
    enabled: true,
    networkId: 'net',
    model: 'qwen.gguf',
  );

  test('starts the model the user asked for when the app opens', () async {
    final cli = _RecordingCli();
    final container = _container(
      prefs: armed,
      cli: cli,
      models: [_model('qwen.gguf')],
      network: _grid('net'),
    );

    await container.read(autoServeStarterProvider).startIfEnabled();

    expect(_joined(cli), isTrue);
    expect(
      cli.starts.first,
      containsAllInOrder(['join', 'net', '--serve', 'qwen.gguf']),
    );
  });

  test('opening the app starts nothing while the box is unticked', () async {
    final cli = _RecordingCli();
    final container = _container(
      prefs: const AutoServePrefs(networkId: 'net', model: 'qwen.gguf'),
      cli: cli,
      models: [_model('qwen.gguf')],
      network: _grid('net'),
    );

    await container.read(autoServeStarterProvider).startIfEnabled();

    expect(_joined(cli), isFalse);
  });

  test(
    'does not join a grid other than the one the model was chosen for',
    () async {
      final cli = _RecordingCli();
      final container = _container(
        prefs: armed,
        cli: cli,
        models: [_model('qwen.gguf')],
        network: _grid('another-grid'),
      );

      await container.read(autoServeStarterProvider).startIfEnabled();

      expect(_joined(cli), isFalse);
    },
  );

  test('a model deleted since it was chosen simply does not start', () async {
    final cli = _RecordingCli();
    final container = _container(prefs: armed, cli: cli, network: _grid('net'));

    await container.read(autoServeStarterProvider).startIfEnabled();

    expect(_joined(cli), isFalse);
  });

  test(
    'a split model missing a shard is left alone — it cannot load',
    () async {
      final cli = _RecordingCli();
      final container = _container(
        prefs: const AutoServePrefs(
          enabled: true,
          networkId: 'net',
          model: 'm-00001-of-00003.gguf',
        ),
        cli: cli,
        models: [_model('m-00001-of-00003.gguf')],
        network: _grid('net'),
      );

      await container.read(autoServeStarterProvider).startIfEnabled();

      expect(_joined(cli), isFalse);
    },
  );

  test('without the engine installed there is nothing to start', () async {
    final cli = _RecordingCli();
    final container = _container(
      prefs: armed,
      cli: cli,
      models: [_model('qwen.gguf')],
      network: _grid('net'),
      engineInstalled: false,
    );

    await container.read(autoServeStarterProvider).startIfEnabled();

    expect(_joined(cli), isFalse);
  });

  test('a second call in the same session does not join twice', () async {
    final cli = _RecordingCli();
    final container = _container(
      prefs: armed,
      cli: cli,
      models: [_model('qwen.gguf')],
      network: _grid('net'),
    );

    final starter = container.read(autoServeStarterProvider);
    await starter.startIfEnabled();
    await starter.startIfEnabled();

    expect(cli.starts.where((args) => args.first == 'join'), hasLength(1));
  });

  group('AutoServePrefs', () {
    test('a record naming no model is switched on but cannot start', () {
      const prefs = AutoServePrefs(enabled: true, networkId: 'net');

      expect(prefs.isArmed, isFalse);
    });

    test('survives the round trip through the file it is stored in', () {
      final file = File('${_tmp.path}/round_trip.json');
      AutoServeStore(file: file).save(
        const AutoServePrefs(
          enabled: true,
          networkId: 'net',
          model: 'qwen.gguf',
          advertiseAs: 'Qwen',
          ctxSize: 8192,
        ),
      );

      final loaded = AutoServeStore(file: file).load();

      expect(loaded.isArmed, isTrue);
      expect(loaded.model, 'qwen.gguf');
      expect(loaded.advertiseAs, 'Qwen');
      expect(loaded.ctxSize, 8192);
    });

    test('an unreadable file reads as off, never as a throw', () {
      final file = File('${_tmp.path}/broken.json')..writeAsStringSync('{');

      expect(AutoServeStore(file: file).load().enabled, isFalse);
    });
  });
}
