import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

NetworkCredential _network(
  String id,
  String name, {
  required List<String> scopes,
}) =>
    NetworkCredential(
      networkId: id,
      name: name,
      networkType: 'permissioned',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: '',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: const ['member'],
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
}

void main() {
  final consumer = _network('grid-con', 'consumer', scopes: const ['consumer:chat']);
  final provider = _network('grid-prov', 'provider',
      scopes: const ['consumer:chat', 'provider:poll']);

  ProviderContainer containerWith(String active) {
    final creds =
        CredentialsFile(networks: [consumer, provider], activeNetwork: active);
    final container = ProviderContainer(
      overrides: [gridHomeStoreProvider.overrideWithValue(_FakeStore(creds))],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('role label reflects the provider scope', () {
    expect(consumer.isProvider, isFalse);
    expect(consumer.roleLabel, 'Consumer');
    expect(provider.isProvider, isTrue);
    expect(provider.roleLabel, 'Provider');
  });

  test('consumer network hides the provider-only sections', () {
    final container = containerWith('grid-con');
    final sections = container.read(visibleNavSectionsProvider);
    expect(sections, [NavSection.networks, NavSection.playground]);
  });

  test('provider network shows every section', () {
    final container = containerWith('grid-prov');
    final sections = container.read(visibleNavSectionsProvider);
    expect(sections, NavSection.values);
  });

  test('switching to a consumer network resets a provider-only section', () {
    final container = containerWith('grid-prov');
    // Keep the notifier alive so its build() registers the reset listener.
    container.listen(navSectionProvider, (_, __) {});

    container.read(navSectionProvider.notifier).select(NavSection.provider);
    expect(container.read(navSectionProvider), NavSection.provider);

    container.read(selectedNetworkProvider.notifier).select(consumer);
    expect(container.read(navSectionProvider), NavSection.networks);
  });
}
