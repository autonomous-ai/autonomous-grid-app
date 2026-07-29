import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/rename_network_controller.dart';
import 'package:grid_app/infrastructure/api/managed_network_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _net = 'net-1';
const _oldName = 'Old Grid';
const _newName = 'New Grid';
const _syncArgs = ['sync'];
const _useArgs = ['use', _net];

NetworkCredential _network({required String id, required String name}) =>
    NetworkCredential(
      networkId: id,
      name: name,
      networkType: 'permissioned-public',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: '',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: const ['admin'],
      scopes: const [],
      memberEpoch: 1,
      networkEpoch: 1,
      expiresAt: 0,
    );

/// Records the name the client was asked to save, so the tests can assert the
/// trimmed value actually reaches the control plane.
class _StubRename {
  _StubRename(this.result);

  final (bool, ManagedNetworkError?) result;
  String? sentName;

  Future<(bool, ManagedNetworkError?)> call({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required String name,
  }) async {
    sentName = name;
    return result;
  }
}

/// A [FakeGridCliService] that records the commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _container({
  required ManagedNetworkRenameFn rename,
  GridCliService? cli,
  String? sessionToken = 'tok',
  List<NetworkCredential>? networks,
  String? activeGrid,
}) {
  final container = ProviderContainer(
    overrides: [
      managedNetworkRenameProvider.overrideWithValue(rename),
      gridCliServiceProvider.overrideWithValue(cli),
      activeRemoteGridProvider.overrideWithValue(activeGrid),
      sessionProvider.overrideWithValue(
        CredentialsFile(
          networks: networks ?? [_network(id: _net, name: _oldName)],
          sessionToken: sessionToken,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('renames, syncs the local list, then reports done', () async {
    final rename = _StubRename((true, null));
    final container = _container(
      rename: rename.call,
      cli: FakeGridCliService(),
    );

    final error = await container
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: _net, name: '  $_newName  ');

    expect(error, isNull);
    expect(rename.sentName, _newName, reason: 'the name is trimmed');
    expect(
      container.read(renameNetworkControllerProvider),
      isA<RenameNetworkDone>(),
    );
  });

  test('runs `grid sync` after a successful rename', () async {
    final cli = _RecordingCli();
    final container = _container(
      rename: _StubRename((true, null)).call,
      cli: cli,
    );

    await container
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: _net, name: _newName);

    expect(cli.runs, contains(equals(_syncArgs)));
  });

  test(
    're-points `grid use` at the id when the renamed grid was active',
    () async {
      final cli = _RecordingCli();
      final container = _container(
        rename: _StubRename((true, null)).call,
        cli: cli,
        activeGrid: _oldName,
      );

      await container
          .read(renameNetworkControllerProvider.notifier)
          .rename(networkId: _net, name: _newName);

      expect(cli.runs, contains(equals(_useArgs)));
    },
  );

  test('leaves the active grid alone when another grid was renamed', () async {
    final cli = _RecordingCli();
    final container = _container(
      rename: _StubRename((true, null)).call,
      cli: cli,
      networks: [
        _network(id: _net, name: _oldName),
        _network(id: 'net-2', name: 'Other Grid'),
      ],
      activeGrid: 'Other Grid',
    );

    await container
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: _net, name: _newName);

    expect(cli.runs, isNot(contains(equals(_useArgs))));
  });

  test(
    'rejects a name another grid already uses, without calling the API',
    () async {
      final rename = _StubRename((true, null));
      final cli = _RecordingCli();
      final container = _container(
        rename: rename.call,
        cli: cli,
        networks: [
          _network(id: _net, name: _oldName),
          _network(id: 'net-2', name: 'Other Grid'),
        ],
      );

      final error = await container
          .read(renameNetworkControllerProvider.notifier)
          .rename(networkId: _net, name: 'other grid');

      expect(error, contains('already have a grid'));
      expect(rename.sentName, isNull);
      expect(cli.runs, isEmpty);
      expect(
        container.read(renameNetworkControllerProvider),
        isA<RenameNetworkFailed>(),
      );
    },
  );

  test('surfaces the API error and does not sync', () async {
    final cli = _RecordingCli();
    final container = _container(
      rename: _StubRename((
        false,
        const ManagedNetworkError('Only the grid owner can rename this grid.'),
      )).call,
      cli: cli,
    );

    final error = await container
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: _net, name: _newName);

    expect(error, contains('owner'));
    expect(cli.runs, isEmpty);
    final state = container.read(renameNetworkControllerProvider);
    expect(state, isA<RenameNetworkFailed>());
    expect((state as RenameNetworkFailed).message, contains('owner'));
  });

  test('fails fast when not signed in', () async {
    final rename = _StubRename((true, null));
    final container = _container(
      rename: rename.call,
      cli: FakeGridCliService(),
      sessionToken: null,
    );

    final error = await container
        .read(renameNetworkControllerProvider.notifier)
        .rename(networkId: _net, name: _newName);

    expect(error, isNotNull);
    expect(rename.sentName, isNull);
    expect(
      container.read(renameNetworkControllerProvider),
      isA<RenameNetworkFailed>(),
    );
  });
}
