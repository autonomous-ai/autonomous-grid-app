import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/getting_started.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(
  String id, {
  required List<String> scopes,
  List<String> roles = const ['member'],
}) =>
    NetworkCredential(
      networkId: id,
      name: id,
      networkType: 'permissioned',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: '',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: roles,
      scopes: scopes,
      memberEpoch: 1,
      networkEpoch: 1,
      expiresAt: 0,
    );

class _FakeStore extends GridHomeStore {
  const _FakeStore(this.credentials);
  final CredentialsFile credentials;

  @override
  CredentialsFile readCredentials() => credentials;

  @override
  String? readActiveRemoteGrid() => null;
}

ProviderContainer _containerWith(List<NetworkCredential> networks) {
  final creds = CredentialsFile(networks: networks);
  final container = ProviderContainer(
    overrides: [gridHomeStoreProvider.overrideWithValue(_FakeStore(creds))],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final consumer = _network('grid-con', scopes: const ['consumer:chat']);
  final provider =
      _network('grid-prov', scopes: const ['consumer:chat', 'provider:poll']);

  test('consumer-only account has no manageable grid and sees the coach', () {
    final container = _containerWith([consumer]);
    expect(container.read(hasManageableGridProvider), isFalse);
    expect(container.read(showGettingStartedProvider), isTrue);
  });

  test('an account with a provider grid can manage and skips the coach', () {
    final container = _containerWith([consumer, provider]);
    expect(container.read(hasManageableGridProvider), isTrue);
    expect(container.read(showGettingStartedProvider), isFalse);
  });

  test('an account with no grids at all has nothing to coach', () {
    final container = _containerWith(const []);
    expect(container.read(showGettingStartedProvider), isFalse);
  });

  test('dismissing hides the coach for the session', () {
    final container = _containerWith([consumer]);
    expect(container.read(showGettingStartedProvider), isTrue);

    container.read(gettingStartedDismissedProvider.notifier).dismiss();

    expect(container.read(gettingStartedDismissedProvider), isTrue);
    expect(container.read(showGettingStartedProvider), isFalse);
  });
}
