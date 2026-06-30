import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/providers.dart';
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

void main() {
  final foo = _network('grid-foo', 'foo');
  final bar = _network('grid-bar', 'bar');

  ProviderContainer containerWith(CredentialsFile creds) {
    final container = ProviderContainer(
      overrides: [gridHomeStoreProvider.overrideWithValue(_FakeStore(creds))],
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
      ],
    );
    addTearDown(container.dispose);
    // state.json `active.cloud` (grid-bar) wins over the legacy active_network.
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
}
