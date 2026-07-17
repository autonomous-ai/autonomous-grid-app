import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_setup_controller.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

ProviderContainer _container({GridCliService? grid}) {
  final container = ProviderContainer(
    overrides: [
      engineStatusProvider.overrideWithValue(EngineStatus.notInstalled),
      gridCliServiceProvider.overrideWithValue(grid),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

FakeGridCliService _grid({
  required int exitCode,
  List<CliLine> lines = const [],
}) => FakeGridCliService()
  ..stubStart(
    const ['engine', 'install', 'llama.cpp'],
    exitCode: exitCode,
    lines: lines,
  );

void main() {
  test(
    'installs the engine with one command — no Homebrew, no Terminal',
    () async {
      final container = _container(
        grid: _grid(
          exitCode: 0,
          lines: const [
            CliLine(isStderr: false, text: 'Installed llama-server'),
          ],
        ),
      );

      await container.read(engineSetupControllerProvider.notifier).run();

      expect(
        container.read(engineSetupControllerProvider),
        isA<EngineSetupDone>(),
      );
    },
  );

  test('a failed install surfaces the last log line', () async {
    final container = _container(
      grid: _grid(
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'SHA-256 mismatch')],
      ),
    );

    await container.read(engineSetupControllerProvider.notifier).run();

    final state = container.read(engineSetupControllerProvider);
    expect(state, isA<EngineSetupFailed>());
    state as EngineSetupFailed;
    expect(state.message, contains('SHA-256 mismatch'));
    expect(state.log, isNotEmpty, reason: 'the detail stays available');
  });

  test('fails with actionable copy when the grid CLI is missing', () async {
    final container = _container();

    await container.read(engineSetupControllerProvider.notifier).run();

    final state = container.read(engineSetupControllerProvider);
    expect(state, isA<EngineSetupFailed>());
    expect((state as EngineSetupFailed).message, contains('Restart the app'));
  });
}
