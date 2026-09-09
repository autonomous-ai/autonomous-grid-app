import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// `credentials.toml` is re-read on every `sessionProvider` invalidation — a
/// `grid sync`, a token refresh, a rename, a grid created or deleted — and each
/// read builds fresh objects. Whether those objects compare equal decides
/// whether the app treats an unchanged file as an unchanged grid.
///
/// It is not a cosmetic question. `selectedNetworkProvider` has 33 watchers,
/// among them the `FutureProvider`s that fetch this grid's models and member
/// usage over the network, and `servingEnginesProvider`, which re-lists
/// `~/.grid/run/engines` and spawns a `kill -0` per record — synchronously, on
/// the UI isolate. Under identity equality every re-read paid all of that for a
/// grid that had not moved.

NetworkCredential _grid(String id, {String token = 'tok'}) => NetworkCredential(
  networkId: id,
  name: id,
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: token,
  refreshToken: '',
  email: 'dev@autonomous.ai',
  nodeId: 'node-$id',
  deviceId: 'device',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// Rebuilds its credentials on every read, exactly as parsing the TOML does.
class _RereadStore extends GridHomeStore {
  _RereadStore(this._build);

  final CredentialsFile Function() _build;
  int reads = 0;

  @override
  CredentialsFile readCredentials() {
    reads++;
    return _build();
  }

  @override
  String? readActiveRemoteGrid() => null;
}

void main() {
  ProviderContainer containerFor(_RereadStore store) {
    final temp = Directory.systemTemp.createTempSync('grid-credentials');
    addTearDown(() => temp.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        gridHomeStoreProvider.overrideWithValue(store),
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${temp.path}/chat_prefs.json')),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('re-reading the same credentials file does not disturb the grid', () {
    final store = _RereadStore(
      () =>
          CredentialsFile(networks: [_grid('net-1')], sessionToken: 'session'),
    );
    final container = containerFor(store);

    var builds = 0;
    final watcher = Provider<int>((ref) {
      ref.watch(selectedNetworkProvider);
      return ++builds;
    });
    container.listen(watcher, (_, _) {}, fireImmediately: true);

    for (var i = 0; i < 5; i++) {
      container.invalidate(sessionProvider);
      container.read(watcher);
    }

    expect(store.reads, 6, reason: 'the file really was re-read each time');
    expect(
      builds,
      1,
      reason: 'an unchanged grid must not fan out to its 33 watchers',
    );
  });

  test('a refreshed access token still reaches everything watching', () {
    var token = 'tok-1';
    final store = _RereadStore(
      () => CredentialsFile(
        networks: [_grid('net-1', token: token)],
        sessionToken: 'session',
      ),
    );
    final container = containerFor(store);

    var builds = 0;
    final watcher = Provider<int>((ref) {
      ref.watch(selectedNetworkProvider);
      return ++builds;
    });
    container.listen(watcher, (_, _) {}, fireImmediately: true);

    // The expiry controller re-reads after writing fresh tokens. That *is* a
    // change, and everything pointed at the grid has to see it — an equality
    // that swallowed this would leave agents holding a dead token.
    token = 'tok-2';
    container.invalidate(sessionProvider);
    container.read(watcher);

    expect(builds, 2);
    expect(container.read(selectedNetworkProvider)?.accessToken, 'tok-2');
  });
}
