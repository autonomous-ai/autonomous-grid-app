import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
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

  @override
  NodeSetupState build() {
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

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = NodeSetupFailed(
        step: steps.first,
        message: 'grid executable not found.',
        log: const [],
      );
      return;
    }

    _cancelled = false;
    final log = <String>[];

    for (var i = 0; i < steps.length; i++) {
      if (_cancelled) return;
      _append(log, '▸ ${steps[i].title}');
      state = NodeSetupRunning(
          steps: steps, index: i, log: List.unmodifiable(log));

      final ok = steps[i].isDownload
          ? await _runDownload(service, steps, i, log)
          : await _runStreaming(service, steps, i, log);
      if (!ok) return; // failure state already set
    }

    if (_cancelled) return;
    _refresh();
    state = NodeSetupDone(steps);
  }

  /// Streaming lifecycle step (`llama.cpp install`, `media install`): success is
  /// `exitCode == 0`, failure surfaces the last log line.
  Future<bool> _runStreaming(
    GridCliService service,
    List<SetupStep> steps,
    int i,
    List<String> log,
  ) async {
    final step = steps[i];
    final process = await service.start(step.args);
    _process = process;
    process.lines.listen((line) {
      _append(log, line.text);
      state = NodeSetupRunning(
          steps: steps, index: i, log: List.unmodifiable(log));
    });

    final exit = await process.exitCode;
    _process = null;
    if (_cancelled) return false;
    if (exit == 0) return true;

    state = NodeSetupFailed(
      step: step,
      message: log.isNotEmpty ? log.last : '${step.title} failed (exit $exit).',
      log: List.unmodifiable(log),
    );
    return false;
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
    _append(log, '✓ ${step.title}');
    return true;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
    _process = null;
    _refresh(); // partial steps may have installed something — rescan.
    state = const NodeSetupIdle();
  }

  /// Back to idle, re-detecting so a retry's plan reflects what already landed.
  void reset() {
    _refresh();
    state = const NodeSetupIdle();
  }

  void _append(List<String> log, String text) {
    log.add(text);
    if (log.length > _maxLogLines) log.removeRange(0, log.length - _maxLogLines);
  }

  void _refresh() {
    ref.invalidate(engineStatusProvider);
    ref.invalidate(localModelsProvider);
    ref.invalidate(nodeCapabilitiesProvider);
  }
}
