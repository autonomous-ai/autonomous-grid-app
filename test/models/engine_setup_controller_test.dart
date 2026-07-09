import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_setup_controller.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/host_shell_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Records whether Terminal was opened, without touching osascript.
class _FakeHostShell implements HostShellService {
  _FakeHostShell({this.terminalOpens = true});

  bool terminalOpens;
  int openCalls = 0;

  @override
  Future<bool> openTerminal(String command) async {
    openCalls++;
    return terminalOpens;
  }
}

/// Mutable flag so a test can flip Homebrew missing → installed between run()
/// (opens Terminal) and continueSetup() (re-checks).
class _Flag {
  _Flag(this.value);
  bool value;
}

ProviderContainer _container({
  required _Flag brew,
  required HostShellService shell,
  GridCliService? grid,
}) {
  final container = ProviderContainer(overrides: [
    homebrewInstalledProvider.overrideWith((ref) => brew.value),
    engineStatusProvider.overrideWithValue(EngineStatus.notInstalled),
    hostShellServiceProvider.overrideWithValue(shell),
    gridCliServiceProvider.overrideWithValue(grid),
  ]);
  addTearDown(container.dispose);
  return container;
}

FakeGridCliService _grid({required int exitCode, List<CliLine> lines = const []}) =>
    FakeGridCliService()
      ..stubStart(
        const ['engine', 'install', 'llama.cpp'],
        exitCode: exitCode,
        lines: lines,
      );

void main() {
  test('installs the engine straight away when Homebrew is present', () async {
    final shell = _FakeHostShell();
    final container = _container(
      brew: _Flag(true),
      shell: shell,
      grid: _grid(exitCode: 0, lines: const [
        CliLine(isStderr: false, text: 'Installed llama-server'),
      ]),
    );

    await container.read(engineSetupControllerProvider.notifier).run();

    expect(container.read(engineSetupControllerProvider), isA<EngineSetupDone>());
    expect(shell.openCalls, 0, reason: 'Homebrew present → no Terminal hop');
  });

  test('opens Terminal for Homebrew, then Continue installs the engine',
      () async {
    final shell = _FakeHostShell();
    final brew = _Flag(false);
    final container = _container(brew: brew, shell: shell, grid: _grid(exitCode: 0));
    final notifier = container.read(engineSetupControllerProvider.notifier);

    await notifier.run();
    expect(container.read(engineSetupControllerProvider),
        isA<EngineSetupAwaitingHomebrew>());
    expect(shell.openCalls, 1);

    // User finishes the Terminal install; Homebrew is now detected.
    brew.value = true;
    await notifier.continueSetup();
    expect(container.read(engineSetupControllerProvider), isA<EngineSetupDone>());
  });

  test('Continue before Homebrew is detected stays waiting with a hint',
      () async {
    final shell = _FakeHostShell();
    final container = _container(
      brew: _Flag(false),
      shell: shell,
      grid: _grid(exitCode: 0),
    );
    final notifier = container.read(engineSetupControllerProvider.notifier);

    await notifier.run();
    await notifier.continueSetup(); // Homebrew still not there

    final state = container.read(engineSetupControllerProvider);
    expect(state, isA<EngineSetupAwaitingHomebrew>());
    expect((state as EngineSetupAwaitingHomebrew).note, isNotNull);
  });

  test('fails when Terminal cannot be opened', () async {
    final shell = _FakeHostShell(terminalOpens: false);
    final container = _container(
      brew: _Flag(false),
      shell: shell,
      grid: _grid(exitCode: 0),
    );

    await container.read(engineSetupControllerProvider.notifier).run();

    final state = container.read(engineSetupControllerProvider);
    expect(state, isA<EngineSetupFailed>());
    state as EngineSetupFailed;
    expect(state.progress.brew, StepStatus.failed);
    expect(state.message, contains('Terminal'));
  });

  test('engine install failure surfaces the last log line, Homebrew stays done',
      () async {
    final shell = _FakeHostShell();
    final container = _container(
      brew: _Flag(true),
      shell: shell,
      grid: _grid(exitCode: 1, lines: const [
        CliLine(isStderr: true, text: 'llama.cpp build failed'),
      ]),
    );

    await container.read(engineSetupControllerProvider.notifier).run();

    final state = container.read(engineSetupControllerProvider);
    expect(state, isA<EngineSetupFailed>());
    state as EngineSetupFailed;
    expect(state.progress.brew, StepStatus.done);
    expect(state.progress.engine, StepStatus.failed);
    expect(state.message, contains('build failed'));
  });
}
