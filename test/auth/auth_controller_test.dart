import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/auth_controller.dart';
import 'package:grid_app/features/auth/logic/auth_state.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

class _FakeStore extends GridHomeStore {
  _FakeStore(this._creds);
  CredentialsFile _creds;
  bool cleared = false;

  @override
  CredentialsFile readCredentials() => _creds;

  @override
  void clearCredentials() {
    cleared = true;
    _creds = CredentialsFile.empty;
  }
}

void main() {
  test('login surfaces the code then succeeds on exit 0', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser', '--api-url', 'https://api.test/'],
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 10),
        lines: const [
          CliLine(isStderr: false, text: 'Open this URL...'),
          CliLine(isStderr: false, text: 'https://x/device-login?user_code=AB-12'),
          CliLine(isStderr: false, text: 'Code: AB-12'),
        ],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        gridApiUrlProvider.overrideWithValue('https://api.test/'),
      ],
    );
    addTearDown(container.dispose);

    final seen = <AuthState>[];
    container.listen(authControllerProvider, (_, next) => seen.add(next));

    await container.read(authControllerProvider.notifier).login();

    expect(container.read(authControllerProvider), isA<AuthSuccess>());
    final awaiting = seen.whereType<AuthAwaitingApproval>();
    expect(awaiting, isNotEmpty);
    expect(awaiting.first.userCode, 'AB-12');
  });

  test('login fails with stderr on non-zero exit', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser', '--api-url', 'https://api.test/'],
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'Grid browser login expired.')],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        gridApiUrlProvider.overrideWithValue('https://api.test/'),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.notifier).login();

    final state = container.read(authControllerProvider);
    expect(state, isA<AuthFailure>());
    expect((state as AuthFailure).message, contains('expired'));
  });

  test('login surfaces a clear, actionable message on an arch-mismatch crash',
      () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['auth', 'login', '--no-browser', '--api-url', 'https://api.test/'],
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
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        gridApiUrlProvider.overrideWithValue('https://api.test/'),
      ],
    );
    addTearDown(container.dispose);

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
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.notifier).login();

    expect(container.read(authControllerProvider), isA<AuthFailure>());
  });

  test('logout clears credentials and resets to idle', () async {
    final store = _FakeStore(
      const CredentialsFile(networks: [], sessionToken: 'tok'),
    );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(FakeGridCliService()),
        gridHomeStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(sessionProvider).isLoggedIn, isTrue);

    await container.read(authControllerProvider.notifier).logout();

    expect(store.cleared, isTrue);
    expect(container.read(authControllerProvider), isA<AuthIdle>());
    expect(container.read(sessionProvider).isLoggedIn, isFalse);
  });
}
