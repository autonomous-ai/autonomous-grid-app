import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/delete_network_controller.dart';
import 'package:grid_app/infrastructure/api/managed_network_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _net = 'net-1';
const _syncArgs = ['sync'];

ManagedNetworkDeleteFn _stubDelete((bool, ManagedNetworkError?) result) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
  }) async => result;
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

NetworkCredential _grid(String id, String name) => NetworkCredential(
  networkId: id,
  name: name,
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['admin'],
  scopes: const ['provider:poll'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// Where the remembered grid is read and written in a test. Never `~/.grid`
/// (§8) — a delete now writes the selection back down, so pointing this at a
/// real home would edit the machine running the suite.
late Directory _temp;

File get _prefsFile => File('${_temp.path}/chat_prefs.json');

ProviderContainer _container({
  required ManagedNetworkDeleteFn delete,
  GridCliService? cli,
  String? sessionToken = 'tok',
  List<NetworkCredential> networks = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      managedNetworkDeleteProvider.overrideWithValue(delete),
      gridCliServiceProvider.overrideWithValue(cli),
      chatPrefsStoreProvider.overrideWithValue(
        ChatPrefsStore(file: _prefsFile),
      ),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: networks, sessionToken: sessionToken),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => _temp = Directory.systemTemp.createTempSync('delete_grid'));
  tearDown(() => _temp.deleteSync(recursive: true));

  test('deletes, syncs the local list, then reports done', () async {
    final container = _container(
      delete: _stubDelete((true, null)),
      cli: FakeGridCliService(),
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, isNull);
    expect(
      container.read(deleteNetworkControllerProvider),
      isA<DeleteNetworkDone>(),
    );
  });

  test('runs `grid sync` after a successful delete', () async {
    final cli = _RecordingCli();
    final container = _container(delete: _stubDelete((true, null)), cli: cli);

    await container.read(deleteNetworkControllerProvider.notifier).delete(_net);

    expect(cli.runs, contains(equals(_syncArgs)));
  });

  test('surfaces the API error and stays failed', () async {
    final container = _container(
      delete: _stubDelete((
        false,
        const ManagedNetworkError('Only the grid owner can delete this grid.'),
      )),
      cli: FakeGridCliService(),
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, contains('owner'));
    final state = container.read(deleteNetworkControllerProvider);
    expect(state, isA<DeleteNetworkFailed>());
    expect((state as DeleteNetworkFailed).message, contains('owner'));
  });

  test('does not sync when the delete fails', () async {
    final cli = _RecordingCli();
    final container = _container(
      delete: _stubDelete((false, const ManagedNetworkError('nope'))),
      cli: cli,
    );

    await container.read(deleteNetworkControllerProvider.notifier).delete(_net);

    expect(cli.runs, isEmpty);
  });

  test('fails fast when not signed in', () async {
    final container = _container(
      delete: _stubDelete((true, null)),
      cli: FakeGridCliService(),
      sessionToken: null,
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, isNotNull);
    expect(
      container.read(deleteNetworkControllerProvider),
      isA<DeleteNetworkFailed>(),
    );
  });

  test('moves off the deleted grid and records where it went', () async {
    // The grid the user was on is already absent from the synced list — this is
    // the state right after `grid sync` drops it.
    final survivor = _grid('net-2', 'Office');
    _prefsFile.writeAsStringSync('{"networkId": "net-1"}');
    final container = _container(
      delete: _stubDelete((true, null)),
      cli: FakeGridCliService(),
      networks: [survivor],
    );

    await container.read(deleteNetworkControllerProvider.notifier).delete(_net);

    expect(
      ChatPrefsStore(file: _prefsFile).load().networkId,
      'net-2',
      reason:
          'a remembered id pointing at a deleted grid reads as "you have not '
          'chosen yet" on the next launch, which is a first-run screen for a '
          'deletion done in Settings',
    );
  });

  test(
    'deleting the last grid records nothing rather than inventing one',
    () async {
      _prefsFile.writeAsStringSync('{"networkId": "net-1"}');
      final container = _container(
        delete: _stubDelete((true, null)),
        cli: FakeGridCliService(),
      );

      await container
          .read(deleteNetworkControllerProvider.notifier)
          .delete(_net);

      expect(ChatPrefsStore(file: _prefsFile).load().networkId, 'net-1');
    },
  );
}
