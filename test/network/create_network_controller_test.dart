import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/create_network_controller.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _net = 'net-1';
const _joinArgs = ['network', 'join', _net];

const _created = ManagedNetwork(
  networkId: _net,
  name: 'my-grid',
  networkType: 'permissioned-public',
  signalingUrl: 'https://signal.example',
  port: 4433,
  status: 'active',
  plan: 'free',
);

ManagedNetworkCreateFn _stubCreate((ManagedNetwork?, String?) result) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async =>
      result;
}

/// Like [_stubCreate] but records the name passed to the create call.
ManagedNetworkCreateFn _recordCreate(
  List<String> names,
  (ManagedNetwork?, String?) result,
) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async {
    names.add(name);
    return result;
  };
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

NetworkCredential _existingNetwork() => NetworkCredential.fromToml(const {
      'network_id': 'net-existing',
      'lan_signaling_url': 'https://signal.example',
      'access_token': 'a',
    });

ProviderContainer _container({
  required ManagedNetworkCreateFn create,
  GridCliService? cli,
  String? sessionToken = 'tok',
  List<NetworkCredential> networks = const [],
  String? email,
}) {
  final container = ProviderContainer(
    overrides: [
      managedNetworkCreateProvider.overrideWithValue(create),
      gridCliServiceProvider.overrideWithValue(cli),
      sessionProvider.overrideWithValue(
        CredentialsFile(
          networks: networks,
          sessionToken: sessionToken,
          user: email == null ? const {} : {'email': email},
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('creates the grid, joins locally, then reports done', () async {
    final fake = FakeGridCliService()
      ..stubResult(_joinArgs,
          const CliResult(exitCode: 0, stdout: 'Joined', stderr: ''));
    final container =
        _container(create: _stubCreate((_created, null)), cli: fake);

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkDone>());
    expect((state as CreateNetworkDone).joinWarning, isNull);
    expect(state.network.networkId, _net);
  });

  test('syncs after joining so the new grid lands fully in ~/.grid', () async {
    final cli = _RecordingCli()
      ..stubResult(_joinArgs,
          const CliResult(exitCode: 0, stdout: 'Joined', stderr: ''));
    final container =
        _container(create: _stubCreate((_created, null)), cli: cli);

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    expect(cli.runs, containsAllInOrder([_joinArgs, const ['sync']]));
  });

  test('surfaces the API error and stays failed', () async {
    final container = _container(
      create: _stubCreate((null, 'You already own a network with this name.')),
      cli: FakeGridCliService(),
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'dup', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkFailed>());
    expect((state as CreateNetworkFailed).message, contains('already own'));
  });

  test('done with a warning when the local join fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(_joinArgs,
          const CliResult(exitCode: 1, stdout: '', stderr: 'join refused'));
    final container =
        _container(create: _stubCreate((_created, null)), cli: fake);

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    final state = container.read(createNetworkControllerProvider);
    expect(state, isA<CreateNetworkDone>());
    expect((state as CreateNetworkDone).joinWarning, contains('join refused'));
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

    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkFailed>());
  });

  test('rejects an empty name before any call', () async {
    final container =
        _container(create: _stubCreate((_created, null)), cli: FakeGridCliService());

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: '   ', type: ManagedNetworkType.permissionedPublic);

    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkFailed>());
  });

  test('createFirstGridIfNeeded provisions a grid named after the user',
      () async {
    final names = <String>[];
    final fake = FakeGridCliService()
      ..stubResult(_joinArgs,
          const CliResult(exitCode: 0, stdout: 'Joined', stderr: ''));
    final container = _container(
      create: _recordCreate(names, (_created, null)),
      cli: fake,
      email: 'huy@gmail.com',
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .createFirstGridIfNeeded();

    expect(names, ['Huy Grid']);
    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkDone>());
  });

  test('createFirstGridIfNeeded is a no-op when a grid already exists',
      () async {
    final names = <String>[];
    final container = _container(
      create: _recordCreate(names, (_created, null)),
      cli: FakeGridCliService(),
      networks: [_existingNetwork()],
      email: 'huy@gmail.com',
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .createFirstGridIfNeeded();

    expect(names, isEmpty);
    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkIdle>());
  });
}
