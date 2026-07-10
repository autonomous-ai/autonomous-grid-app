import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(String id, String name) => NetworkCredential(
  networkId: id,
  name: name,
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

class _FakeStore extends GridHomeStore {
  const _FakeStore(this.credentials, {this.activeRemote});
  final CredentialsFile credentials;
  final String? activeRemote;

  @override
  CredentialsFile readCredentials() => credentials;

  @override
  String? readActiveRemoteGrid() => activeRemote;
}

/// Like [_FakeStore] but its credentials can change between reads, so a test can
/// simulate what `grid sync` writes to disk and then invalidate [sessionProvider].
class _MutableStore extends GridHomeStore {
  _MutableStore(this.credentials);
  CredentialsFile credentials;

  @override
  CredentialsFile readCredentials() => credentials;

  @override
  String? readActiveRemoteGrid() => null;
}

void main() {
  final foo = _network('grid-foo', 'foo');
  final bar = _network('grid-bar', 'bar');

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_session_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  // Point the remembered-selection store at a temp file so tests never read or
  // write the real `~/.grid/app/chat_prefs.json` (and start with no saved grid).
  prefsOverride() => chatPrefsStoreProvider.overrideWithValue(
    ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
  );

  ProviderContainer containerWith(CredentialsFile creds) {
    final container = ProviderContainer(
      overrides: [
        gridHomeStoreProvider.overrideWithValue(_FakeStore(creds)),
        prefsOverride(),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('selected network falls back to legacy active_network', () {
    final container = containerWith(
      CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-bar'),
    );
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');
  });

  test('selected network honors the state.json active grid (grid use)', () {
    final container = ProviderContainer(
      overrides: [
        gridHomeStoreProvider.overrideWithValue(
          _FakeStore(
            CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-foo'),
            activeRemote: 'grid-bar',
          ),
        ),
        prefsOverride(),
      ],
    );
    addTearDown(container.dispose);
    // state.json `active.cloud` (grid-bar) wins over the legacy active_network.
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');
  });

  test('restores the last used grid over the on-disk default', () {
    // The user last picked foo; the CLI default is bar. Reopening the app lands
    // on foo so they don't have to re-select.
    ChatPrefsStore(
      file: File('${tmp.path}/chat_prefs.json'),
    ).save(const ChatPrefs(networkId: 'grid-foo'));
    final container = ProviderContainer(
      overrides: [
        gridHomeStoreProvider.overrideWithValue(
          _FakeStore(
            CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-bar'),
          ),
        ),
        prefsOverride(),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-foo');
  });

  test('ignores a remembered grid that no longer exists', () {
    ChatPrefsStore(
      file: File('${tmp.path}/chat_prefs.json'),
    ).save(const ChatPrefs(networkId: 'grid-gone'));
    final container = containerWith(
      CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-bar'),
    );
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');
  });

  test('switching network is pure app state', () {
    final container = containerWith(
      CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-bar'),
    );
    container.read(selectedNetworkProvider.notifier).select(foo);
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-foo');
  });

  test('no networks → not logged in, null selection', () {
    final container = containerWith(CredentialsFile.empty);
    expect(container.read(sessionProvider).isLoggedIn, isFalse);
    expect(container.read(selectedNetworkProvider), isNull);
  });

  test('keeps the user selection across a session refresh (grid sync)', () {
    // The user picks bar; the post-join `grid sync` invalidates the session.
    // Selection must stay on bar, not snap back to the default (foo) — that
    // reset is what bounced the user off the Engines tab onto Grids.
    final container = containerWith(
      CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-foo'),
    );
    container.read(selectedNetworkProvider.notifier).select(bar);
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');

    container.invalidate(sessionProvider); // re-read after `grid sync`
    expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');
  });

  test(
    'falls back to the default when the selected grid vanishes after sync',
    () {
      final store = _MutableStore(
        CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-foo'),
      );
      final container = ProviderContainer(
        overrides: [
          gridHomeStoreProvider.overrideWithValue(store),
          prefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      container.read(selectedNetworkProvider.notifier).select(bar);
      expect(container.read(selectedNetworkProvider)!.networkId, 'grid-bar');

      // A sync drops bar from the account; selection falls back gracefully.
      store.credentials = CredentialsFile(
        networks: [foo],
        activeNetwork: 'grid-foo',
      );
      container.invalidate(sessionProvider);
      expect(container.read(selectedNetworkProvider)!.networkId, 'grid-foo');
    },
  );
}
