import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/models/logic/model_group.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/node_setup/logic/auto_host_controller.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _model = 'qwen3.gguf';

/// A grid the user owns. [provider] mirrors whether their token already carries
/// the `provider:poll` scope — i.e. whether sharing is already set up.
NetworkCredential _grid({
  bool owner = true,
  bool provider = false,
  bool public = false,
}) => NetworkCredential(
  networkId: 'ag-1',
  name: 'My AI Grid',
  networkType: public ? 'permissionless' : 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'me@x.com',
  nodeId: 'node',
  deviceId: 'dev',
  roles: owner ? const ['admin'] : const ['consumer'],
  scopes: provider ? const ['provider:poll'] : const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// Pins the active grid, since the real one resolves from disk.
class _FixedNetwork extends SelectedNetwork {
  _FixedNetwork(this.network);
  final NetworkCredential? network;

  @override
  NetworkCredential? build() => network;
}

/// A store with no engine run records — nothing to adopt on restart.
class _NoRunsStore extends GridHomeStore {
  const _NoRunsStore();

  @override
  List<EngineRunRecord> listEngineRuns(String gridId) => const [];
}

ModelGroup _group() => ModelGroup(
  displayName: 'Qwen3',
  files: const [LocalModel(name: _model, path: '/m/$_model', sizeBytes: 1)],
  primary: const LocalModel(name: _model, path: '/m/$_model', sizeBytes: 1),
  isSplit: false,
);

({ProviderContainer container, FakeGridCliService cli}) _harness({
  NetworkCredential? network,
  bool engineInstalled = true,
  bool hasModel = true,
  bool canHost = true,
}) {
  final cli = FakeGridCliService()
    ..stubResult(
      ['ctx', '--json', _model],
      const CliResult(
        exitCode: 0,
        stdout: '{"context_length": 8192}',
        stderr: '',
      ),
    );

  final container = ProviderContainer(
    overrides: [
      supportsBuiltInEngineProvider.overrideWithValue(canHost),
      gridCliServiceProvider.overrideWithValue(cli),
      gridHomeStoreProvider.overrideWithValue(const _NoRunsStore()),
      sessionProvider.overrideWithValue(
        const CredentialsFile(
          networks: [],
          sessionToken: 'session',
          user: {'email': 'me@x.com'},
        ),
      ),
      selectedNetworkProvider.overrideWith(() => _FixedNetwork(network)),
      engineStatusProvider.overrideWithValue(
        engineInstalled
            ? const EngineStatus(llamaInstalled: true, llamaPath: '/bin/llama')
            : EngineStatus.notInstalled,
      ),
      modelGroupsProvider.overrideWithValue(hasModel ? [_group()] : const []),
      freePortFinderProvider.overrideWithValue(() async => 51234),
      nodeNameProvider.overrideWithValue('my-mac'),
      syncDelayAfterJoinProvider.overrideWithValue(Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, cli: cli);
}

void main() {
  test('shares the computer: grants the provider role, then joins', () async {
    final h = _harness(network: _grid());

    await h.container.read(autoHostControllerProvider.notifier).startIfReady();

    expect(h.container.read(autoHostControllerProvider), isA<AutoHostDone>());
    final join = h.cli.lastStartArgs!;
    expect(join.take(4), ['join', 'ag-1', '--serve', _model]);
    expect(join, contains('--ctx-size'));
    expect(join, containsAllInOrder(['--name', 'my-mac']));
  });

  test('skips the role grant when sharing is already set up', () async {
    final h = _harness(network: _grid(provider: true));

    await h.container.read(autoHostControllerProvider.notifier).startIfReady();

    expect(h.container.read(autoHostControllerProvider), isA<AutoHostDone>());
    expect(h.cli.lastStartArgs!.first, 'join');
  });

  test(
    'runs at most once — a stopped engine is not restarted behind the user',
    () async {
      final h = _harness(network: _grid(provider: true));
      final controller = h.container.read(autoHostControllerProvider.notifier);

      await controller.startIfReady();
      h.cli.lastStartArgs = null;
      await controller.startIfReady();

      expect(h.cli.lastStartArgs, isNull);
    },
  );

  group('waits instead of acting', () {
    test('no grid yet — the starter grid is still being provisioned', () async {
      final h = _harness(network: null);

      await h.container
          .read(autoHostControllerProvider.notifier)
          .startIfReady();

      expect(h.cli.lastStartArgs, isNull);
      expect(h.container.read(autoHostControllerProvider), isA<AutoHostIdle>());
    });

    test('engine not installed yet', () async {
      final h = _harness(network: _grid(), engineInstalled: false);

      await h.container
          .read(autoHostControllerProvider.notifier)
          .startIfReady();

      expect(h.cli.lastStartArgs, isNull);
    });

    test('no model downloaded yet', () async {
      final h = _harness(network: _grid(), hasModel: false);

      await h.container
          .read(autoHostControllerProvider.notifier)
          .startIfReady();

      expect(h.cli.lastStartArgs, isNull);
    });
  });

  group('never acts', () {
    test(
      "on someone else's grid — a guest is a consumer, not a host",
      () async {
        final h = _harness(network: _grid(owner: false));

        await h.container
            .read(autoHostControllerProvider.notifier)
            .startIfReady();

        expect(h.cli.lastStartArgs, isNull);
        expect(
          h.container.read(autoHostControllerProvider),
          isA<AutoHostIdle>(),
        );
      },
    );

    test(
      'on a public grid — strangers would get this computer without the user '
      'ever choosing to offer it',
      () async {
        final h = _harness(network: _grid(provider: true, public: true));

        await h.container
            .read(autoHostControllerProvider.notifier)
            .startIfReady();

        expect(h.cli.lastStartArgs, isNull);
        expect(
          h.container.read(autoHostControllerProvider),
          isA<AutoHostIdle>(),
        );
      },
    );

    test('on a machine that cannot host (Linux, Windows)', () async {
      final h = _harness(network: _grid(), canHost: false);

      await h.container
          .read(autoHostControllerProvider.notifier)
          .startIfReady();

      expect(h.cli.lastStartArgs, isNull);
    });
  });

  test('a failed role grant surfaces, and never joins', () async {
    final h = _harness(network: _grid());
    h.cli.stubResult([
      'members',
      'add',
      'ag-1',
      'me@x.com',
      '--role',
      'provider',
    ], const CliResult(exitCode: 1, stdout: '', stderr: 'seat limit reached'));

    await h.container.read(autoHostControllerProvider.notifier).startIfReady();

    final state = h.container.read(autoHostControllerProvider);
    expect(state, isA<AutoHostFailed>());
    expect((state as AutoHostFailed).message, contains('seat limit'));
    expect(h.cli.lastStartArgs, isNull, reason: 'no provider role, no join');
  });
}
