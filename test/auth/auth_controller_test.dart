import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/auth_controller.dart';
import 'package:grid_app/features/auth/logic/auth_state.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/cli_auth.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

/// Fully in-memory store: overrides every `~/.grid` read/write the controller
/// touches so tests never reach the real filesystem (logout actually clears
/// cli.toml, which must not run against the developer's own session).
class _FakeStore extends GridHomeStore {
  _FakeStore({
    CredentialsFile creds = CredentialsFile.empty,
    CliAuth auth = CliAuth.empty,
  })  : _creds = creds,
        _auth = auth;

  CredentialsFile _creds;
  CliAuth _auth;
  bool credentialsCleared = false;
  bool cliAuthCleared = false;

  @override
  CredentialsFile readCredentials() => _creds;

  @override
  CliAuth readCliAuth() => _auth;

  @override
  void clearCredentials() {
    credentialsCleared = true;
    _creds = CredentialsFile.empty;
  }

  @override
  void clearCliAuth() {
    cliAuthCleared = true;
    _auth = CliAuth.empty;
  }
}

ProviderContainer _container(GridCliService? service, {GridHomeStore? store}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(service),
      gridHomeStoreProvider.overrideWithValue(store ?? _FakeStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('login surfaces the code then succeeds on exit 0', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser'],
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 10),
        lines: const [
          CliLine(isStderr: false, text: 'Open this URL...'),
          CliLine(isStderr: false, text: 'https://x/device-login?user_code=AB-12'),
          CliLine(isStderr: false, text: 'Code: AB-12'),
        ],
      );
    final container = _container(fake);

    final seen = <AuthState>[];
    container.listen(authControllerProvider, (_, next) => seen.add(next));

    await container.read(authControllerProvider.notifier).login();

    expect(container.read(authControllerProvider), isA<AuthSuccess>());
    final awaiting = seen.whereType<AuthAwaitingApproval>();
    expect(awaiting, isNotEmpty);
    expect(awaiting.first.userCode, 'AB-12');
  });

  test('login streams the raw CLI output to the log', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser'],
        exitCode: 0,
        lines: const [
          CliLine(isStderr: false, text: 'https://x/device-login?user_code=AB-12'),
          CliLine(isStderr: false, text: 'Code: AB-12'),
        ],
      );
    final container = _container(fake);

    await container.read(authControllerProvider.notifier).login();

    final log = container.read(authLogProvider);
    expect(log.first, r'$ grid auth login --no-browser');
    expect(log, contains('Code: AB-12'));
  });

  test('login fails with stderr on non-zero exit', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser'],
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'Grid browser login expired.')],
      );
    final container = _container(fake);

    await container.read(authControllerProvider.notifier).login();

    final state = container.read(authControllerProvider);
    expect(state, isA<AuthFailure>());
    expect((state as AuthFailure).message, contains('expired'));
  });

  test('login surfaces a clear, actionable message on an arch-mismatch crash',
      () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser'],
        exitCode: 1,
        lines: const [
          CliLine(isStderr: true, text: 'Traceback (most recent call last):'),
          CliLine(
              isStderr: true,
              text: "ImportError: dlopen(...protocol.cpython-313-darwin.so): "
                  "mach-o file, but is an incompatible architecture "
                  "(have 'arm64', need 'x86_64')"),
        ],
      );
    final container = _container(fake);

    await container.read(authControllerProvider.notifier).login();

    final state = container.read(authControllerProvider);
    expect(state, isA<AuthFailure>());
    final message = (state as AuthFailure).message;
    expect(message, contains('architecture'));
    expect(message, contains('Rosetta'));
    // The raw Python traceback must not leak into the message.
    expect(message, isNot(contains('Traceback')));
  });

  test('login fails fast when grid is absent', () async {
    final container = _container(null);

    await container.read(authControllerProvider.notifier).login();

    expect(container.read(authControllerProvider), isA<AuthFailure>());
  });

  test('logout clears the cli auth + credentials and resets to idle', () async {
    final store = _FakeStore(
      creds: const CredentialsFile(networks: [], sessionToken: 'tok'),
      auth: const CliAuth(apiKey: 'key', userId: 'a@b.com'),
    );
    final container = _container(FakeGridCliService(), store: store);

    expect(container.read(authSessionProvider).isAuthenticated, isTrue);

    await container.read(authControllerProvider.notifier).logout();

    expect(store.cliAuthCleared, isTrue);
    expect(store.credentialsCleared, isTrue);
    expect(container.read(authControllerProvider), isA<AuthIdle>());
    expect(container.read(authSessionProvider).isAuthenticated, isFalse);
  });
}
