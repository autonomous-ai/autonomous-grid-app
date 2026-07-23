import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/logging/node_setup_log.dart';
import '../../../infrastructure/providers.dart';
import '../../agents/logic/agent_status.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import 'node_capabilities.dart';
import 'node_setup_plan.dart';

final nodeSetupControllerProvider =
    NotifierProvider<NodeSetupController, NodeSetupState>(
      NodeSetupController.new,
    );

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

/// The run reached the end. [completed] lists only the steps that actually
/// succeeded — empty when the node was already set up, and short of the plan
/// when an optional step was skipped ([SetupStep.optional]).
class NodeSetupDone extends NodeSetupState {
  const NodeSetupDone(this.completed);
  final List<SetupStep> completed;
}

/// Why a setup run stopped, which decides how loudly the UI speaks about it.
/// [error] is a genuine failure (a crash, a broken download) → the red bar.
/// [unsupported] means the computer simply can't host the built-in engine — no
/// GPU to run it on, or no build for its CPU. Nothing is broken, so the auto
/// flow surfaces it as a calm notice rather than an alarm the moment the app
/// opens.
enum NodeSetupFailureKind { error, unsupported }

class NodeSetupFailed extends NodeSetupState {
  const NodeSetupFailed({
    required this.step,
    required this.message,
    required this.log,
    this.kind = NodeSetupFailureKind.error,
  });

  final SetupStep step;
  final String message;
  final List<String> log;

  /// Severity of the stop — see [NodeSetupFailureKind].
  final NodeSetupFailureKind kind;
}

/// Orchestrates the "set up this computer as a node" sequence: runs each
/// [SetupStep] in order through the `grid` CLI, streaming a combined log, and
/// stops at the first failure. On success it re-detects engines/models so the
/// UI reflects the new state. One owned process at a time, killed on dispose.
class NodeSetupController extends Notifier<NodeSetupState> {
  static const _maxLogLines = 400;
  GridProcess? _process;
  bool _cancelled = false;
  late final NodeSetupLog _logFile;

  @override
  NodeSetupState build() {
    _logFile = ref.read(nodeSetupLogProvider);
    ref.onDispose(() => _process?.kill());
    return const NodeSetupIdle();
  }

  /// Runs [steps] in order, stopping at the first failure. Driven by the
  /// first-run installer, and by the Engines tab when a user sets the machine up
  /// by hand — one implementation, so the two can't disagree.
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
    final completed = <SetupStep>[];

    for (var i = 0; i < steps.length; i++) {
      if (_cancelled) return; // cancel() writes its own footer
      _logFile.startStep(i + 1, steps.length, steps[i].title);
      _memo(log, '▸ ${steps[i].title}');
      state = NodeSetupRunning(
        steps: steps,
        index: i,
        log: List.unmodifiable(log),
      );

      final ok = steps[i].isDownload
          ? await _runDownload(service, steps, i, log)
          : await _runStreaming(service, steps, i, log);
      if (_cancelled) return; // cancel() writes its own footer
      if (!ok) {
        if (_skipOptional(steps, i, log)) continue;
        _logFile.endStep('failed');
        final failure = state;
        _logFile.endRun(
          failure is NodeSetupFailed
              ? 'FAILED — ${failure.step.title}: ${failure.message}'
              : 'stopped',
        );
        return; // failure state already set
      }
      _logFile.endStep('done');
      completed.add(steps[i]);
    }

    if (_cancelled) return;
    _refresh();
    _logFile.endRun('completed — ${completed.length} step(s)');
    state = NodeSetupDone(completed);
  }

  /// Whether step [i] may be left behind: an optional step that failed is noted
  /// and the run continues, so one extra assistant that wouldn't download can't
  /// stop a first run that already has the one answering chat.
  ///
  /// The failure state the step just set is dropped here — the *next* iteration
  /// re-arms [NodeSetupRunning], and the loop's tail turns the run into
  /// [NodeSetupDone] with only what actually succeeded. Returns false for a
  /// required step, leaving its failure to stop the run.
  bool _skipOptional(List<SetupStep> steps, int i, List<String> log) {
    if (!steps[i].optional) return false;
    final failure = state;
    final why = failure is NodeSetupFailed ? failure.message : 'it failed';
    _logFile.endStep('skipped — $why');
    _memo(log, '… skipped ${steps[i].title}: $why');
    return true;
  }

  /// Streaming lifecycle step (`llama.cpp install`, `media install`): success is
  /// `exitCode == 0`, failure surfaces a humanized message ([_describeFailure]).
  Future<bool> _runStreaming(
    GridCliService service,
    List<SetupStep> steps,
    int i,
    List<String> log,
  ) async {
    final step = steps[i];
    final process = await service.start(step.args);
    _process = process;
    final sub = process.lines.listen((line) {
      // Ignore a line that arrives after this step ended (cancel, failure, or
      // the next step already started) — it must not revive a stale
      // "Running step i" state and hang the spinner forever.
      if (_cancelled || state is! NodeSetupRunning) return;
      _output(log, line);
      state = NodeSetupRunning(
        steps: steps,
        index: i,
        log: List.unmodifiable(log),
      );
    });

    final exit = await process.exitCode;
    await sub.cancel();
    _process = null;
    if (_cancelled) return false;
    if (exit == 0) return true;

    final failure = _describeFailure(step, log, exit);
    state = NodeSetupFailed(
      step: step,
      message: failure.message,
      kind: failure.kind,
      log: List.unmodifiable(log),
    );
    return false;
  }

  /// CLI failures that mean "this computer simply can't host an engine", not
  /// "something broke": a Linux box with no GPU to run one on, or a CPU
  /// architecture we publish no build for. Nothing is wrong — the user can still
  /// use an engine someone else shares — so these get a calm notice rather than
  /// an alarm. (The engine install itself no longer needs Homebrew, so its old
  /// "Homebrew is required" failure is gone.)
  static const _unsupportedMarkers = [
    'no nvidia gpus detected',
    'no prebuilt llama.cpp',
  ];

  /// Map a raw CLI failure to plain language + severity at the controller
  /// boundary (§6). Everything outside [_unsupportedMarkers] keeps the CLI's own
  /// last line as a genuine [error].
  static ({String message, NodeSetupFailureKind kind}) _describeFailure(
    SetupStep step,
    List<String> log,
    int exit,
  ) {
    final raw = log.isNotEmpty ? log.last : '';
    final lowered = raw.toLowerCase();
    if (_unsupportedMarkers.any(lowered.contains)) {
      return (
        kind: NodeSetupFailureKind.unsupported,
        message:
            "This computer can't run AI models on its own hardware. You "
            'can still use an engine shared by another computer on your grid.',
      );
    }
    return (
      kind: NodeSetupFailureKind.error,
      message: raw.isNotEmpty ? raw : '${step.title} failed (exit $exit).',
    );
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
    if (log.length > _maxLogLines) {
      log.removeRange(0, log.length - _maxLogLines);
    }
  }

  /// Re-read everything a completed (or half-completed) plan can have changed.
  ///
  /// The agents belong here as much as the engine does: a plan's
  /// `grid agent install hermes` step leaves the binary on PATH, and without
  /// this the app went on answering with the probe it took at launch — the
  /// Agents tab said "Not installed" and chat skipped the agent entirely, on a
  /// machine that had just installed one.
  void _refresh() {
    reprobeAgents(ref);
    ref.invalidate(engineStatusProvider);
    ref.invalidate(localModelsProvider);
    ref.invalidate(nodeCapabilitiesProvider);
  }
}
