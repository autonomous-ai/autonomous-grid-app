import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/create_network_controller.dart';
import 'package:grid_app/infrastructure/api/managed_network_client.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

const _net = 'net-1';
const _syncArgs = ['sync'];
const _useArgs = ['use', _net];

const _created = ManagedNetwork(
  networkId: _net,
  name: 'my-grid',
  networkType: 'permissioned-public',
  signalingUrl: 'https://signal.example',
  port: 4433,
  status: 'active',
  plan: 'free',
);

ManagedNetworkCreateFn _stubCreate(
  (ManagedNetwork?, ManagedNetworkError?) result,
) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async => result;
}

/// A [FakeGridCliService] that records the lifecycle commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _container({
  required ManagedNetworkCreateFn create,
  GridCliService? cli,
  String? sessionToken = 'tok',
}) {
  final container = ProviderContainer(
    overrides: [
      managedNetworkCreateProvider.overrideWithValue(create),
      gridCliServiceProvider.overrideWithValue(cli),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: const [], sessionToken: sessionToken),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('creates the grid, syncs + selects it, then reports done', () async {
    final container = _container(
      create: _stubCreate((_created, null)),
      cli: FakeGridCliService(),
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkDone>());
    expect((state as CreateNetworkDone).joinWarning, isNull);
    expect(state.network.networkId, _net);
  });

  test('syncs then selects the new grid with `grid use`', () async {
    final cli = _RecordingCli();
    final container = _container(
      create: _stubCreate((_created, null)),
      cli: cli,
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    expect(cli.runs, containsAllInOrder([_syncArgs, _useArgs]));
  });

  test('surfaces the API error and stays failed', () async {
    final container = _container(
      create: _stubCreate((
        null,
        const ManagedNetworkError('You already own a network with this name.'),
      )),
      cli: FakeGridCliService(),
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'dup', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkFailed>());
    expect((state as CreateNetworkFailed).message, contains('already own'));
  });

  test('done with a warning when the local sync fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(
        _syncArgs,
        const CliResult(exitCode: 1, stdout: '', stderr: 'sync refused'),
      );
    final container = _container(
      create: _stubCreate((_created, null)),
      cli: fake,
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkDone>());
    expect((state as CreateNetworkDone).joinWarning, contains('sync refused'));
  });

  test('fails fast when not signed in', () async {
    final container = _container(
      create: _stubCreate((_created, null)),
      cli: FakeGridCliService(),
      sessionToken: null,
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    expect(
      container.read(createNetworkControllerProvider),
      isA<CreateNetworkFailed>(),
    );
  });

  test('rejects an empty name before any call', () async {
    final container = _container(
      create: _stubCreate((_created, null)),
      cli: FakeGridCliService(),
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: '   ', type: ManagedNetworkType.permissionedPublic);

    expect(
      container.read(createNetworkControllerProvider),
      isA<CreateNetworkFailed>(),
    );
  });
}
