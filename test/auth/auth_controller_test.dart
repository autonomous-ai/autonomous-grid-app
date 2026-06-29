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

class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

void main() {
  test('login surfaces the code then succeeds on exit 0', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['login', '--no-browser'],
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 10),
        lines: const [
          CliLine(isStderr: false, text: 'Open this URL...'),
          CliLine(isStderr: false, text: 'https://x/device-login?user_code=AB-12'),
          CliLine(isStderr: false, text: 'Code: AB-12'),
        ],
      );
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
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

  test('login shows a friendly message on non-zero exit (no raw stderr)',
      () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['login', '--no-browser'],
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'Grid browser login expired.')],
      );
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.notifier).login();

    final state = container.read(authControllerProvider);
    expect(state, isA<AuthFailure>());
    // Raw CLI stderr is mapped to plain language, not surfaced verbatim.
    final message = (state as AuthFailure).message;
    expect(message, contains('try again'));
    expect(message, isNot(contains('Grid browser login')));
  });

  test('login fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.notifier).login();

    expect(container.read(authControllerProvider), isA<AuthFailure>());
  });

  test('logout runs `grid logout` and resets to idle', () async {
    final cli = _RecordingCli();
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(cli)],
    );
    addTearDown(container.dispose);

    await container.read(authControllerProvider.notifier).logout();

    expect(cli.runs, contains(equals(const ['logout'])));
    expect(container.read(authControllerProvider), isA<AuthIdle>());
  });

  test('logout without the CLI clears local credentials directly', () async {
    final store = _FakeStore(
      const CredentialsFile(networks: [], sessionToken: 'tok'),
    );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(null),
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
