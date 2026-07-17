import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_expiry_controller.dart';
import 'package:grid_app/features/onboarding/preflight_providers.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

/// A [FakeGridCliService] that records the lifecycle commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

/// Store with no networks, so session recovery has nothing to refresh — keeps
/// these tests off the real `~/.grid` and deterministic.
class _EmptyStore extends GridHomeStore {
  const _EmptyStore();

  @override
  CredentialsFile readCredentials() => CredentialsFile.empty;
}

ProviderContainer _containerWith(GridCliService cli, {GridHomeStore? store}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      if (store != null) gridHomeStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('runs grid sync right after a successful version check', () async {
    final cli = _RecordingCli()
      ..stubResult([
        '--version',
      ], const CliResult(exitCode: 0, stdout: 'grid 0.2.0', stderr: ''));
    final container = _containerWith(cli);

    final report = await container.read(preflightProvider.future);

    expect(report.gridAvailable, isTrue);
    expect(cli.runs.first, ['--version']);
    expect(cli.runs, contains(equals(const ['sync'])));
  });

  test('skips sync when the grid CLI is unavailable', () async {
    final cli = _RecordingCli()
      ..stubResult([
        '--version',
      ], const CliResult(exitCode: 1, stdout: '', stderr: 'boom'));
    final container = _containerWith(cli);

    final report = await container.read(preflightProvider.future);

    expect(report.gridAvailable, isFalse);
    expect(cli.runs, isNot(contains(equals(const ['sync']))));
  });

  test('triggers session recovery when grid sync reports an expiry', () async {
    final cli = _RecordingCli()
      ..stubResult([
        '--version',
      ], const CliResult(exitCode: 0, stdout: 'grid 0.2.0', stderr: ''))
      ..stubResult(
        ['sync'],
        const CliResult(
          exitCode: 1,
          stdout: '',
          stderr:
              'Grid session expired or invalid. '
              'Run `grid auth login` to sign in again.',
        ),
      );
    final container = _containerWith(cli, store: const _EmptyStore());

    final report = await container.read(preflightProvider.future);
    expect(report.gridAvailable, isTrue);

    // Sync runs off the critical path — let its result land before asserting.
    // With no network to refresh, recovery lands on needs-login.
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sessionExpiryProvider), SessionExpiry.needsLogin);
  });

  test('leaves the session healthy on an ordinary sync failure', () async {
    final cli = _RecordingCli()
      ..stubResult([
        '--version',
      ], const CliResult(exitCode: 0, stdout: 'grid 0.2.0', stderr: ''))
      ..stubResult(
        ['sync'],
        const CliResult(exitCode: 1, stdout: '', stderr: 'Network unreachable'),
      );
    final container = _containerWith(cli, store: const _EmptyStore());

    await container.read(preflightProvider.future);

    await Future<void>.delayed(Duration.zero);
    expect(container.read(sessionExpiryProvider), SessionExpiry.healthy);
  });
}
