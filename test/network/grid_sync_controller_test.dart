import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/auth/logic/session_expiry_controller.dart';
import 'package:grid_app/features/network/logic/grid_sync_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

const _syncArgs = ['sync'];

/// A [FakeGridCliService] that records the lifecycle commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _container({GridCliService? cli}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      sessionProvider.overrideWithValue(
        const CredentialsFile(networks: [], sessionToken: 'tok', user: {}),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('starts idle', () {
    final container = _container(cli: FakeGridCliService());
    expect(container.read(gridSyncControllerProvider), isA<GridSyncIdle>());
  });

  test('runs `grid sync` and reports done', () async {
    final cli = _RecordingCli();
    final container = _container(cli: cli);

    await container.read(gridSyncControllerProvider.notifier).sync();

    expect(cli.runs, contains(equals(_syncArgs)));
    expect(container.read(gridSyncControllerProvider), isA<GridSyncDone>());
  });

  test('fails with a friendly message when the CLI is missing', () async {
    final container = _container(cli: null);

    await container.read(gridSyncControllerProvider.notifier).sync();

    final state = container.read(gridSyncControllerProvider);
    expect(state, isA<GridSyncFailed>());
    expect((state as GridSyncFailed).message, contains('CLI'));
  });

  test('fails with a friendly message when sync errors', () async {
    final fake = FakeGridCliService()
      ..stubResult(
        _syncArgs,
        const CliResult(exitCode: 1, stdout: '', stderr: 'sync refused'),
      );
    final container = _container(cli: fake);

    await container.read(gridSyncControllerProvider.notifier).sync();

    final state = container.read(gridSyncControllerProvider);
    expect(state, isA<GridSyncFailed>());
    // Raw stderr stays out of the primary message (it lives in the Debug log).
    expect((state as GridSyncFailed).message, isNot(contains('sync refused')));
  });

  test(
    'hands an expired session to the app banner instead of failing',
    () async {
      final fake = FakeGridCliService()
        ..stubResult(
          _syncArgs,
          const CliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'session expired or invalid',
          ),
        );
      final container = _container(cli: fake);

      await container.read(gridSyncControllerProvider.notifier).sync();

      expect(container.read(gridSyncControllerProvider), isA<GridSyncIdle>());
      expect(
        container.read(sessionExpiryProvider),
        isNot(SessionExpiry.healthy),
      );
    },
  );
}
