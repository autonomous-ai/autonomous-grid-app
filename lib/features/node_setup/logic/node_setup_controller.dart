import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/logging/node_setup_log.dart';
import '../../../infrastructure/providers.dart';
import '../../models/logic/llama_install_controller.dart';
import '../../models/logic/models_providers.dart';
import 'node_capabilities.dart';
import 'node_setup_plan.dart';

final nodeSetupControllerProvider =
    NotifierProvider<NodeSetupController, NodeSetupState>(
        NodeSetupController.new);

sealed class NodeSetupState {
  const NodeSetupState();
}

class NodeSetupIdle extends NodeSetupState {
  const NodeSetupIdle();
}

/// Running step [index] of [steps]; [log] holds the latest streamed lines and
/// [progress] is the current download bar (null for non-download steps).
class NodeSetupRunning extends NodeSetupState {
  const NodeSetupRunning({
    required this.steps,
    required this.index,
    required this.log,
    this.progress,
  });

  final List<SetupStep> steps;
  final int index;
  final List<String> log;
  final DownloadProgress? progress;

  SetupStep get current => steps[index];
}

/// Every step finished. [completed] is empty when the node was already set up.
class NodeSetupDone extends NodeSetupState {
  const NodeSetupDone(this.completed);
  final List<SetupStep> completed;
}

class NodeSetupFailed extends NodeSetupState {
  const NodeSetupFailed({
    required this.step,
    required this.message,
    required this.log,
  });

  final SetupStep step;
  final String message;
  final List<String> log;
}

/// Orchestrates the "set up this computer as a node" sequence: runs each
/// [SetupStep] in order through the `grid` CLI, streaming a combined log, and
/// stops at the first failure. On success it re-detects engines/models so the
/// UI reflects the new state. One owned process at a time, killed on dispose.
class NodeSetupController extends Notifier<NodeSetupState> {
  static const _maxLogLines = 400;
  GridProcess? _process;
  bool _cancelled = false;
  bool _autoStarted = false;
  late final NodeSetupLog _logFile;

  @override
  NodeSetupState build() {
    _logFile = ref.read(nodeSetupLogProvider);
    ref.onDispose(() => _process?.kill());
    return const NodeSetupIdle();
  }

  /// Hands-off background entry point: starts setup once per app session when
  /// there are gaps to fill. A no-op if it already auto-started, or if a run is
  /// in flight. After a cancel/failure the user resumes via [run] — we don't
  /// auto-restart and nag. Returns immediately when [steps] is empty.
  Future<void> autoStart(List<SetupStep> steps) async {
    if (_autoStarted || steps.isEmpty || state is! NodeSetupIdle) return;
    _autoStarted = true;
    await run(steps);
  }

  Future<void> run(List<SetupStep> steps) async {
    if (state is NodeSetupRunning) return;
    if (steps.isEmpty) {
      state = const NodeSetupDone([]);
      return;
    }

    _logFile.startRun(steps.map((s) => s.title).toList());

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      const message = 'grid executable not found.';
      _logFile.endRun('FAILED — $message');
      state = NodeSetupFailed(
        step: steps.first,
        message: message,
        log: const [],
      );
      return;
    }

    _cancelled = false;
    final log = <String>[];

    for (var i = 0; i < steps.length; i++) {
      if (_cancelled) return; // cancel() writes its own footer
      _logFile.startStep(i + 1, steps.length, steps[i].title);
      _memo(log, '▸ ${steps[i].title}');
      state = NodeSetupRunning(
          steps: steps, index: i, log: List.unmodifiable(log));

      final ok = await _runStep(service, steps, i, log);
      if (_cancelled) return; // cancel() writes its own footer
      if (!ok) {
        _logFile.endStep('failed');
        final failure = state;
        _logFile.endRun(failure is NodeSetupFailed
            ? 'FAILED — ${failure.step.title}: ${failure.message}'
            : 'stopped');
        return; // failure state already set
      }
      _logFile.endStep('done');
    }

    if (_cancelled) return;
    _refresh();
    _logFile.endRun('completed — ${steps.length} step(s)');
    state = NodeSetupDone(steps);
  }

  /// Routes a step to its runner: Homebrew through the [HomebrewInstaller],
  /// downloads through the progress path, everything else through the CLI.
  Future<bool> _runStep(
    GridCliService service,
    List<SetupStep> steps,
    int i,
    List<String> log,
  ) {
    final step = steps[i];
    return switch (step.action) {
      SetupAction.installHomebrew => _runProcess(
          steps,
          i,
          log,
          () => ref.read(homebrewInstallerProvider).install(),
          _friendlyHomebrewError,
        ),
      _ => step.isDownload
          ? _runDownload(service, steps, i, log)
          : _runProcess(
              steps,
              i,
              log,
              () => service.start(step.args),
              (exit, lines) =>
                  lines.isNotEmpty ? lines.last : '${step.title} failed (exit $exit).',
            ),
    };
  }

  /// Shared runner for streaming, process-backed steps (CLI install, Homebrew
  /// install): mirror each line, then succeed on `exitCode == 0` or fail with a
  /// message built by [onFailure]. [spawn] defers process start so the owned
  /// [_process] handle is set right before we listen.
  Future<bool> _runProcess(
    List<SetupStep> steps,
    int i,
    List<String> log,
    Future<GridProcess> Function() spawn,
    String Function(int exit, List<String> log) onFailure,
  ) async {
    final process = await spawn();
    _process = process;
    process.lines.listen((line) {
      _output(log, line);
      state = NodeSetupRunning(
          steps: steps, index: i, log: List.unmodifiable(log));
    });

    final exit = await process.exitCode;
    _process = null;
    if (_cancelled) return false;
    if (exit == 0) return true;

    state = NodeSetupFailed(
      step: steps[i],
      message: onFailure(exit, log),
      log: List.unmodifiable(log),
    );
    return false;
  }

  /// Humanize a Homebrew-install failure — the raw script output stays in the
  /// log; the user sees a plain, actionable line.
  static String _friendlyHomebrewError(int exit, List<String> log) {
    final joined = log.join('\n').toLowerCase();
    if (joined.contains('administrator permission was declined') ||
        joined.contains('user cancelled') ||
        joined.contains('user canceled')) {
      return 'Setup needs your Mac administrator password to install the engine '
          'tools. Try again and enter your password when macOS asks for it.';
    }
    return "Couldn't install the setup tools (Homebrew). Check your internet "
        'connection and try again.';
  }

  /// Download step (`models pull`, `media pull`): success is the progress stream
  /// completing without error.
  Future<bool> _runDownload(
    GridCliService service,
    List<SetupStep> steps,
    int i,
    List<String> log,
  ) async {
    final step = steps[i];
    try {
      await for (final progress in service.pull(step.args)) {
        if (_cancelled) return false;
        state = NodeSetupRunning(
          steps: steps,
          index: i,
          log: List.unmodifiable(log),
          progress: progress,
        );
      }
    } catch (error) {
      state = NodeSetupFailed(
        step: step,
        message: error.toString(),
        log: List.unmodifiable(log),
      );
      return false;
    }
    if (_cancelled) return false;
    _memo(log, '✓ ${step.title}');
    return true;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
    _process = null;
    if (state is NodeSetupRunning) {
      _logFile.endStep('cancelled');
      _logFile.endRun('cancelled by user');
    }
    _refresh(); // partial steps may have installed something — rescan.
    state = const NodeSetupIdle();
  }

  /// Back to idle, re-detecting so a retry's plan reflects what already landed.
  void reset() {
    _refresh();
    state = const NodeSetupIdle();
  }

  /// Mirror one streamed line to both the durable file (tagging stderr) and the
  /// in-memory UI log.
  void _output(List<String> log, CliLine line) {
    _logFile.write(line.text, isError: line.isStderr);
    _memo(log, line.text);
  }

  /// Append to the in-memory UI log only, capped at [_maxLogLines].
  void _memo(List<String> log, String text) {
    log.add(text);
    if (log.length > _maxLogLines) log.removeRange(0, log.length - _maxLogLines);
  }

  void _refresh() {
    ref.invalidate(engineStatusProvider);
    ref.invalidate(localModelsProvider);
    ref.invalidate(nodeCapabilitiesProvider);
  }
}
