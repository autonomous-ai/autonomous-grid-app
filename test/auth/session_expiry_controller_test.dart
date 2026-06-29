import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_expiry_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(String id) => NetworkCredential(
      networkId: id,
      name: id,
      networkType: 'permissioned',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: 'refresh-$id',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: const ['member'],
      scopes: const ['consumer:chat'],
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

class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _container({
  required CredentialsFile creds,
  required GridCliService cli,
  String apiUrl = '',
}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      gridHomeStoreProvider.overrideWithValue(_FakeStore(creds)),
      gridApiUrlProvider.overrideWithValue(apiUrl),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

CredentialsFile _loggedIn(String networkId) => CredentialsFile(
      networks: [_network(networkId)],
      activeNetwork: networkId,
      sessionToken: 'session-tok',
    );

void main() {
  test('refreshes the active network token and recovers silently', () async {
    final cli = _RecordingCli();
    final container = _container(creds: _loggedIn('grid-1'), cli: cli);

    await container.read(sessionExpiryProvider.notifier).onExpired();

    expect(container.read(sessionExpiryProvider), SessionExpiry.healthy);
    expect(cli.runs, contains(equals(['auth', 'refresh', '--network', 'grid-1'])));
  });

  test('passes --api-url through to refresh when configured', () async {
    final cli = _RecordingCli();
    final container =
        _container(creds: _loggedIn('grid-1'), cli: cli, apiUrl: 'https://api.test/');

    await container.read(sessionExpiryProvider.notifier).onExpired();

    expect(
      cli.runs,
      contains(equals([
        'auth', 'refresh', '--network', 'grid-1', //
        '--api-url', 'https://api.test/',
      ])),
    );
  });

  test('prompts re-login when refresh fails', () async {
    final cli = _RecordingCli()
      ..stubResult(['auth', 'refresh', '--network', 'grid-1'],
          const CliResult(exitCode: 1, stdout: '', stderr: 'refresh token expired'));
    final container = _container(creds: _loggedIn('grid-1'), cli: cli);

    await container.read(sessionExpiryProvider.notifier).onExpired();

    expect(container.read(sessionExpiryProvider), SessionExpiry.needsLogin);
  });

  test('needs login when there is no network to refresh', () async {
    final cli = _RecordingCli();
    final container = _container(creds: CredentialsFile.empty, cli: cli);

    await container.read(sessionExpiryProvider.notifier).onExpired();

    expect(container.read(sessionExpiryProvider), SessionExpiry.needsLogin);
    expect(cli.runs, isEmpty);
  });
}
