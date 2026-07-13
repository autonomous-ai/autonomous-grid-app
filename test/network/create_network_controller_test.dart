import 'dart:async';

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
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

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

ManagedNetworkCreateFn _stubCreate((ManagedNetwork?, ManagedNetworkError?) result) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async =>
      result;
}

/// Like [_stubCreate] but records the name (and optionally the type) passed to
/// the create call.
ManagedNetworkCreateFn _recordCreate(
  List<String> names,
  (ManagedNetwork?, ManagedNetworkError?) result, {
  List<ManagedNetworkType>? types,
}) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async {
    names.add(name);
    types?.add(type);
    return result;
  };
}

/// Records the create name and returns [future], so a test can hold the create
/// open (state stays [CreateNetworkSubmitting]) and probe re-entrancy.
ManagedNetworkCreateFn _hangingCreate(
  List<String> names,
  Future<(ManagedNetwork?, ManagedNetworkError?)> future,
) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) {
    names.add(name);
    return future;
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

/// A grid already in `credentials.toml`. [roles] decides whether the user owns
/// it (`admin`) or was merely invited onto someone else's — the two cases the
/// auto-provision gate must tell apart.
NetworkCredential _existingNetwork({List<String> roles = const ['admin']}) =>
    NetworkCredential.fromToml({
      'network_id': 'net-existing',
      'lan_signaling_url': 'https://signal.example',
      'access_token': 'a',
      'roles': roles,
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
  test('creates the grid, syncs + selects it, then reports done', () async {
    final container = _container(
        create: _stubCreate((_created, null)), cli: FakeGridCliService());

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
    final container =
        _container(create: _stubCreate((_created, null)), cli: cli);

    await container
        .read(createNetworkControllerProvider.notifier)
        .submit(name: 'my-grid', type: ManagedNetworkType.permissionedPublic);

    expect(cli.runs, containsAllInOrder([_syncArgs, _useArgs]));
  });

  test('surfaces the API error and stays failed', () async {
    final container = _container(
      create: _stubCreate(
          (null, const ManagedNetworkError('You already own a network with this name.'))),
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
      ..stubResult(_syncArgs,
          const CliResult(exitCode: 1, stdout: '', stderr: 'sync refused'));
    final container =
        _container(create: _stubCreate((_created, null)), cli: fake);

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
    final container = _container(
      create: _recordCreate(names, (_created, null)),
      cli: FakeGridCliService(),
      email: 'huy@gmail.com',
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .createFirstGridIfNeeded();

    expect(names, ['Huy AI Grid']);
    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkDone>());
  });

  test('createFirstGridIfNeeded provisions a private grid', () async {
    // A grid the user never asked for must not be open to strangers. Asserted on
    // the wire value, not the enum name — the names read backwards on purpose
    // (permissionedProviders IS `permissioned-public`, the Private one).
    final names = <String>[];
    final types = <ManagedNetworkType>[];
    final container = _container(
      create: _recordCreate(names, (_created, null), types: types),
      cli: FakeGridCliService(),
      email: 'huy@gmail.com',
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .createFirstGridIfNeeded();

    expect(types.single.wire, 'permissioned-public');
    expect(types.single.label, 'Private');
  });

  test('createFirstGridIfNeeded skips a second call while a create is in flight',
      () async {
    final names = <String>[];
    final gate = Completer<(ManagedNetwork?, ManagedNetworkError?)>();
    final container = _container(
      create: _hangingCreate(names, gate.future),
      cli: FakeGridCliService(),
      email: 'huy@gmail.com',
    );
    final notifier = container.read(createNetworkControllerProvider.notifier);

    // First call kicks off a create that hasn't resolved — state is Submitting.
    final first = notifier.createFirstGridIfNeeded();
    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkSubmitting>());

    // A second call while it's in flight must not fire another create.
    await notifier.createFirstGridIfNeeded();
    expect(names, ['Huy AI Grid']);

    gate.complete((_created, null));
    await first;
  });

  test('createFirstGridIfNeeded is a no-op when the user already owns a grid',
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

  test('createFirstGridIfNeeded still provisions for a guest on someone '
      "else's grid", () async {
    // Invited onto a colleague's grid but owning none: without a grid of their
    // own they can't share a model anywhere, so they still need the starter one.
    final names = <String>[];
    final container = _container(
      create: _recordCreate(names, (_created, null)),
      cli: FakeGridCliService(),
      networks: [_existingNetwork(roles: const ['consumer'])],
      email: 'huy@gmail.com',
    );

    await container
        .read(createNetworkControllerProvider.notifier)
        .createFirstGridIfNeeded();

    expect(names, ['Huy AI Grid']);
    expect(container.read(createNetworkControllerProvider),
        isA<CreateNetworkDone>());
  });
}
