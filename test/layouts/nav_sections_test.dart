import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

NetworkCredential _network(
  String id,
  String name, {
  required List<String> scopes,
  List<String> roles = const ['member'],
}) => NetworkCredential(
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

  // No state.json in tests — fall back to the legacy active_network so the
  // active selection stays deterministic (not the dev machine's ~/.grid).
  @override
  String? readActiveRemoteGrid() => null;
}

void main() {
  final consumer = _network(
    'grid-con',
    'consumer',
    scopes: const ['consumer:chat'],
  );
  final provider = _network(
    'grid-prov',
    'provider',
    scopes: const ['consumer:chat', 'provider:poll'],
  );

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_nav_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  // Keep the remembered-selection store off the real `~/.grid` (empty, so the
  // active grid stays the on-disk default rather than a saved pick).
  prefsOverride() => chatPrefsStoreProvider.overrideWithValue(
    ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
  );

  ProviderContainer containerWith(String active) {
    final creds = CredentialsFile(
      networks: [consumer, provider],
      activeNetwork: active,
    );
    final container = ProviderContainer(
      overrides: [
        gridHomeStoreProvider.overrideWithValue(_FakeStore(creds)),
        prefsOverride(),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('roleLabel reflects the roles claim — not the provider:poll scope', () {
    // The provider:poll scope is a capability, not a governance role.
    expect(consumer.isProvider, isFalse);
    expect(provider.isProvider, isTrue);

    // An admin keeps the Owner label even without provider:poll (the bug:
    // it used to fall back to "Consumer" because it read scopes, not roles).
    final admin = _network(
      'grid-adm',
      'admin',
      roles: const ['admin'],
      scopes: const ['network:sync'],
    );
    expect(admin.role, NetworkRole.admin);
    expect(admin.roleLabel, 'Owner');
    expect(admin.isProvider, isFalse);

    final consumerRole = _network(
      'grid-c2',
      'c2',
      roles: const ['consumer'],
      scopes: const ['inference:create'],
    );
    expect(consumerRole.role, NetworkRole.consumer);
    // Role labels deliberately avoid Public/Private (reserved for visibility).
    expect(consumerRole.roleLabel, 'Using');
  });

  test('settings opens on Grids, the screen a returning admin reaches for', () {
    final container = containerWith('grid-prov');
    expect(container.read(settingsTabProvider), SettingsTab.grids);
  });

  test('a deep-link switches the settings tab (no nested dialog)', () {
    // Cards inside the settings dialog — "Set up engine", "How it works" —
    // switch the tab rather than stacking another dialog on top.
    final container = containerWith('grid-prov');
    container.listen(settingsTabProvider, (_, _) {});

    container.read(settingsTabProvider.notifier).select(SettingsTab.engines);
    expect(container.read(settingsTabProvider), SettingsTab.engines);

    container.read(settingsTabProvider.notifier).select(SettingsTab.howToUse);
    expect(container.read(settingsTabProvider), SettingsTab.howToUse);
  });

  test('switching grid leaves the open settings tab alone', () {
    final container = containerWith('grid-prov');
    container.listen(settingsTabProvider, (_, _) {});
    container.read(settingsTabProvider.notifier).select(SettingsTab.engines);

    container.read(selectedNetworkProvider.notifier).select(consumer);

    expect(container.read(settingsTabProvider), SettingsTab.engines);
  });
}
