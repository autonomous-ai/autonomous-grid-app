import 'dart:async';

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

/// A [GridCliService] whose streaming process is driven line-by-line by the
/// test: it hands back a [GridProcess] fed from [lines] with an exit code the
/// test resolves via [exit], so a late line can be flushed after the step ends.
class _ScriptedProcessCli implements GridCliService {
  _ScriptedProcessCli(this.lines, this.exit);

  final StreamController<CliLine> lines;
  final Completer<int> exit;

  @override
  Future<GridProcess> start(List<String> args,
          {Map<String, String>? environment}) async =>
      GridProcess(lines: lines.stream, exitCode: exit.future, kill: () {});

  @override
  Future<CliResult> run(List<String> args) async =>
      const CliResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Stream<DownloadProgress> pull(List<String> args) =>
      const Stream<DownloadProgress>.empty();
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

ProviderContainer _container(GridCliService? fake, {NodeSetupLog? log}) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(fake),
    gridHomeStoreProvider.overrideWithValue(const _EmptyStore()),
    // Always override so no test ever writes to the real ~/.grid/logs.
    nodeSetupLogProvider.overrideWithValue(log ?? _RecordingLog()),
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
    // A generic CLI failure is a real error (red bar), not the soft notice.
    expect(state.kind, NodeSetupFailureKind.error);
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

  test('an empty plan is done, not "running nothing"', () async {
    final container = _container(FakeGridCliService());

    await container.read(nodeSetupControllerProvider.notifier).run(const []);

    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupDone>());
  });

  test('humanizes a computer that cannot host an engine at all', () async {
    // A Linux box with no GPU: nothing is broken, this machine just can't run a
    // model itself. Say so plainly, and point at the way out (someone else's
    // engine) — not at a raw CLI line.
    final fake = FakeGridCliService()
      ..stubStart(['engine', 'install', 'llama.cpp'], exitCode: 1, lines: const [
        CliLine(
          isStderr: true,
          text: 'No NVIDIA GPUs detected (nvidia-smi missing or returned '
              'nothing). Pass --target-sm <sm_XX> to override.',
        ),
      ]);
    final container = _container(fake);

    await container
        .read(nodeSetupControllerProvider.notifier)
        .run([_llamaStep, _modelStep]);

    final state = container.read(nodeSetupControllerProvider);
    expect(state, isA<NodeSetupFailed>());
    expect((state as NodeSetupFailed).message, contains('shared by another'));
    expect(state.message, isNot(contains('nvidia-smi')));
    // Can't-host is a soft "not ready" notice, not a red error.
    expect(state.kind, NodeSetupFailureKind.unsupported);
  });

  test('a late line after a step fails does not revive the running state',
      () async {
    // A streamed step can flush a buffered stderr tail after it has already
    // exited non-zero; that line must not flip the card back to "Running step
    // 1/1" and spin forever (there is no process left).
    final lines = StreamController<CliLine>();
    final exit = Completer<int>();
    final container = _container(_ScriptedProcessCli(lines, exit));
    final notifier = container.read(nodeSetupControllerProvider.notifier);

    final run = notifier.run([_llamaStep]);
    await Future<void>.delayed(Duration.zero); // let the listener subscribe
    lines.add(const CliLine(isStderr: true, text: 'working'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupRunning>());

    exit.complete(1); // the step fails
    await run;
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupFailed>());

    // A tail line arriving after the failure is dropped, not re-run.
    lines.add(const CliLine(isStderr: true, text: 'late tail'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(nodeSetupControllerProvider), isA<NodeSetupFailed>());

    await lines.close();
  });
}
