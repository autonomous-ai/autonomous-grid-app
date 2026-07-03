import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/node_setup/logic/node_setup_controller.dart';
import 'package:grid_app/features/node_setup/logic/node_setup_plan.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/logging/node_setup_log.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:grid_app/infrastructure/system/homebrew_installer.dart';

class _EmptyStore extends GridHomeStore {
  const _EmptyStore();
  @override
  List<LocalModel> listLocalModels() => const [];
}

/// In-memory [NodeSetupLog] so tests never touch the real `~/.grid/logs`.
/// Records the run boundaries and every mirrored line for assertions.
class _RecordingLog implements NodeSetupLog {
  final List<String> lines = []; // streamed output lines
  final List<String> stepTitles = []; // titles of started steps
  final List<String> stepResults = []; // done/failed/cancelled per step
  List<String>? runPlan;
  String? runOutcome;

  @override
  void startRun(List<String> stepTitles) => runPlan = stepTitles;

  @override
  void startStep(int number, int total, String title) => stepTitles.add(title);

  @override
  void write(String line, {bool isError = false}) => lines.add(line);

  @override
  void endStep(String result) => stepResults.add(result);

  @override
  void endRun(String outcome) => runOutcome = outcome;
}

/// In-memory [HomebrewInstaller]: reports missing/installed and streams a canned
/// install, flipping to installed on a zero exit — no real Homebrew touched.
class _FakeHomebrew implements HomebrewInstaller {
  _FakeHomebrew({
    this.exitCode = 0,
    this.lines = const [],
  });

  bool installed = false;
  final int exitCode;
  final List<CliLine> lines;
  int installCalls = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isInstalled => installed;

  @override
  Future<GridProcess> install() async {
    installCalls++;
    return GridProcess(
      lines: Stream.fromIterable(lines),
      exitCode: Future.delayed(const Duration(milliseconds: 5), () {
        if (exitCode == 0) installed = true;
        return exitCode;
      }),
      kill: () {},
    );
  }
}

const _llamaStep = SetupStep(
  action: SetupAction.installLlama,
  title: 'Install llama.cpp',
  detail: '',
  args: ['engine', 'install', 'llama.cpp'],
  isDownload: false,
);

const _modelStep = SetupStep(
  action: SetupAction.pullModel,
  title: 'Download model',
  detail: '',
  args: ['pull', 'm'],
  isDownload: true,
);

const _brewStep = SetupStep(
  action: SetupAction.installHomebrew,
  title: 'Install setup tools',
  detail: '',
  args: [],
  isDownload: false,
);

ProviderContainer _container(
  GridCliService? fake, {
  NodeSetupLog? log,
  HomebrewInstaller? brew,
}) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(fake),
    gridHomeStoreProvider.overrideWithValue(const _EmptyStore()),
    // Always override so no test ever writes to the real ~/.grid/logs.
    nodeSetupLogProvider.overrideWithValue(log ?? _RecordingLog()),
    if (brew != null) homebrewInstallerProvider.overrideWithValue(brew),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('runs an install then a download to completion', () async {
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 0,
          exitDelay: const Duration(milliseconds: 5),
          lines: const [CliLine(isStderr: false, text: 'Linked llama-server')])
      ..stubPull(['pull', 'm'], const [
        DownloadProgress(doneMb: 50, totalMb: 100, pct: 50),
        DownloadProgress(doneMb: 100, totalMb: 100, pct: 100),
      ]);
    final container = _container(fake);

    final seen = <NodeSetupState>[];
    container.listen(nodeSetupControllerProvider, (_, next) => seen.add(next));

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep, _modelStep]);

    final state = container.read(nodeSetupControllerProvider);
    expect(state, isA<NodeSetupDone>());
    expect((state as NodeSetupDone).completed, hasLength(2));
    // Saw a streamed install line and a download progress update along the way.
    expect(
      seen.whereType<NodeSetupRunning>().where((s) => s.progress != null),
      isNotEmpty,
    );
  });

  test('stops at the first failed step', () async {
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 1,
          lines: const [CliLine(isStderr: true, text: 'brew: not found')]);
    final container = _container(fake);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep, _modelStep]);

    final state = container.read(nodeSetupControllerProvider);
    expect(state, isA<NodeSetupFailed>());
    expect((state as NodeSetupFailed).step.action, SetupAction.installLlama);
    expect(state.message, contains('brew'));
  });

  test('an empty plan completes immediately', () async {
    final container = _container(FakeGridCliService());

    await container.read(nodeSetupControllerProvider.notifier).run(const []);

    final state = container.read(nodeSetupControllerProvider);
    expect(state, isA<NodeSetupDone>());
    expect((state as NodeSetupDone).completed, isEmpty);
  });

  test('fails fast when grid is absent', () async {
    final container = _container(null);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep]);

    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupFailed>());
  });

  test('mirrors the full transcript and a success footer to the log file',
      () async {
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 0,
          lines: const [CliLine(isStderr: false, text: 'Linked llama-server')])
      ..stubPull(['pull', 'm'], const [
        DownloadProgress(doneMb: 100, totalMb: 100, pct: 100),
      ]);
    final log = _RecordingLog();
    final container = _container(fake, log: log);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep, _modelStep]);

    expect(log.runPlan, contains('Install llama.cpp'));
    expect(log.stepTitles, contains('Install llama.cpp'));
    expect(log.lines, contains('Linked llama-server')); // streamed CLI output
    expect(log.stepResults, everyElement('done'));
    expect(log.runOutcome, contains('completed'));
  });

  test('records the failing step and message in the log footer', () async {
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 1,
          lines: const [CliLine(isStderr: true, text: 'brew: not found')]);
    final log = _RecordingLog();
    final container = _container(fake, log: log);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep, _modelStep]);

    expect(log.lines, contains('brew: not found'));
    expect(log.runOutcome, contains('FAILED'));
    expect(log.runOutcome, contains('brew'));
  });

  test('logs a footer when grid is absent', () async {
    final log = _RecordingLog();
    final container = _container(null, log: log);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep]);

    expect(log.runOutcome, contains('FAILED'));
    expect(log.runOutcome, contains('grid executable not found'));
  });

  test('autoStart with an empty plan stays idle', () async {
    final container = _container(FakeGridCliService());

    await container.read(nodeSetupControllerProvider.notifier).autoStart(const []);

    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupIdle>());
  });

  test('autoStart runs once, then is a no-op', () async {
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 0, lines: const [CliLine(isStderr: false, text: 'ok')]);
    final container = _container(fake);
    final notifier = container.read(nodeSetupControllerProvider.notifier);

    await notifier.autoStart([_llamaStep]);
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupDone>());

    // A second auto-start (e.g. after capabilities re-detect) must not re-run.
    await notifier.autoStart([_llamaStep]);
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupDone>());
  });

  test('installs Homebrew through the installer before the engine step',
      () async {
    final brew = _FakeHomebrew(lines: const [
      CliLine(isStderr: false, text: 'Homebrew installed successfully'),
    ]);
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'],
          exitCode: 0,
          lines: const [CliLine(isStderr: false, text: 'Linked llama-server')]);
    final container = _container(fake, brew: brew);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_brewStep, _llamaStep]);

    expect(brew.installCalls, 1);
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupDone>());
  });

  test('a failed Homebrew step stops setup with a friendly message', () async {
    final brew = _FakeHomebrew(exitCode: 1, lines: const [
      CliLine(isStderr: true, text: 'Administrator permission was declined.'),
    ]);
    final container = _container(FakeGridCliService(), brew: brew);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_brewStep, _llamaStep]);

    final state = container.read(nodeSetupControllerProvider);
    expect(state, isA<NodeSetupFailed>());
    expect((state as NodeSetupFailed).step.action, SetupAction.installHomebrew);
    // Humanized, not the raw script line, and never the wrong internet/disk hint.
    expect(state.message, contains('administrator password'));
  });
}
