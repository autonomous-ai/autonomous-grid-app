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
  List<String> roles = const ['member'],
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

  test('roleLabel reflects the roles claim — not the provider:poll scope', () {
    // The provider:poll scope is a capability, not a governance role.
    expect(consumer.isProvider, isFalse);
    expect(provider.isProvider, isTrue);

    // An admin keeps the Admin label even without provider:poll (the bug:
    // it used to fall back to "Consumer" because it read scopes, not roles).
    final admin = _network('grid-adm', 'admin',
        roles: const ['admin'], scopes: const ['network:sync']);
    expect(admin.role, NetworkRole.admin);
    expect(admin.roleLabel, 'Admin');
    expect(admin.isProvider, isFalse);

    final consumerRole = _network('grid-c2', 'c2',
        roles: const ['consumer'], scopes: const ['inference:create']);
    expect(consumerRole.role, NetworkRole.consumer);
    expect(consumerRole.roleLabel, 'Public');
  });

  test('consumer network hides the provider-only sections', () {
    final container = containerWith('grid-con');
    final sections = container.read(visibleNavSectionsProvider);
    // Provider/Models are hidden; Debug is dev-only, so it shows here because
    // tests run in debug mode (kDebugMode) — it's gone in release builds.
    expect(sections,
        [NavSection.networks, NavSection.playground, NavSection.debug]);
  });

  test('provider network shows every section', () {
    final container = containerWith('grid-prov');
    final sections = container.read(visibleNavSectionsProvider);
    expect(sections, NavSection.values);
  });

  test('admin network shows every section without provider:poll', () {
    final admin = _network('grid-adm', 'admin',
        roles: const ['admin'], scopes: const ['network:sync']);
    final creds = CredentialsFile(networks: [admin], activeNetwork: 'grid-adm');
    final container = ProviderContainer(
      overrides: [gridHomeStoreProvider.overrideWithValue(_FakeStore(creds))],
    );
    addTearDown(container.dispose);

    expect(admin.isProvider, isFalse);
    expect(admin.canManageProvider, isTrue);
    expect(container.read(visibleNavSectionsProvider), NavSection.values);
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
