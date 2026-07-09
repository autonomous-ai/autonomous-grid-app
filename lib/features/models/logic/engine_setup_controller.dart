import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../infrastructure/providers.dart';
import 'engine_status.dart';

/// Status of one step in the built-in-engine setup checklist.
enum StepStatus { pending, running, done, failed }

/// The checklist shared across states: install Homebrew (the macOS package
/// installer the engine build needs), then the llama.cpp engine. [log] is the
/// live output of the engine step (the Homebrew step runs in Terminal).
class EngineSetupProgress {
  const EngineSetupProgress({
    this.brew = StepStatus.pending,
    this.engine = StepStatus.pending,
    this.log = const [],
  });

  final StepStatus brew;
  final StepStatus engine;
  final List<String> log;

  EngineSetupProgress copyWith({
    StepStatus? brew,
    StepStatus? engine,
    List<String>? log,
  }) =>
      EngineSetupProgress(
        brew: brew ?? this.brew,
        engine: engine ?? this.engine,
        log: log ?? this.log,
      );
}

/// State of the built-in-engine setup flow.
sealed class EngineSetupState {
  const EngineSetupState();
}

/// Nothing running yet — the initial state and where a fresh flow starts.
class EngineSetupIdle extends EngineSetupState {
  const EngineSetupIdle();
}

/// The Homebrew installer was opened in Terminal; waiting for the user to finish
/// there (type their password) and press Continue. [note] is an optional hint,
/// e.g. after a Continue that didn't yet detect Homebrew.
class EngineSetupAwaitingHomebrew extends EngineSetupState {
  const EngineSetupAwaitingHomebrew(this.progress, {this.note});
  final EngineSetupProgress progress;
  final String? note;
}

/// The engine step is streaming; [progress] carries per-step status + the log.
class EngineSetupRunning extends EngineSetupState {
  const EngineSetupRunning(this.progress);
  final EngineSetupProgress progress;
}

/// Both steps finished; the engine is ready to serve a model.
class EngineSetupDone extends EngineSetupState {
  const EngineSetupDone();
}

/// A step failed. [progress] keeps the checklist so the UI shows which step
/// stopped; [message] is user-facing.
class EngineSetupFailed extends EngineSetupState {
  const EngineSetupFailed(this.progress, this.message);
  final EngineSetupProgress progress;
  final String message;
}

final engineSetupControllerProvider =
    NotifierProvider<EngineSetupController, EngineSetupState>(
        EngineSetupController.new);

/// Orchestrates built-in engine setup as a visible checklist: install Homebrew,
/// then run `grid engine install llama.cpp`.
///
/// Homebrew's official installer needs an interactive `sudo` a GUI app can't
/// provide, so we open it in Terminal ([run] → [HostShellService.openTerminal])
/// and wait for the user to finish and press Continue ([continueSetup]), then
/// re-check and install the engine. When Homebrew is already present the
/// Terminal hop is skipped and the engine installs straight away.
class EngineSetupController extends Notifier<EngineSetupState> {
  static const _maxLogLines = 300;

  /// The official Homebrew install one-liner, run in Terminal so its `sudo`
  /// prompt has a real tty. `\$` keeps the shell's command-substitution literal.
  static const _brewInstallCommand =
      '/bin/bash -c "\$(curl -fsSL '
      'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"';

  GridProcess? _gridProcess;

  @override
  EngineSetupState build() {
    ref.onDispose(() => _gridProcess?.kill());
    return const EngineSetupIdle();
  }

  /// Starts setup. Installs the engine straight away when Homebrew is present;
  /// otherwise opens the official installer in Terminal and waits for Continue.
  Future<void> run() async {
    if (ref.read(homebrewInstalledProvider)) {
      await _installEngineStep(const EngineSetupProgress(brew: StepStatus.done));
      return;
    }
    final opened =
        await ref.read(hostShellServiceProvider).openTerminal(_brewInstallCommand);
    if (!opened) {
      state = const EngineSetupFailed(
        EngineSetupProgress(brew: StepStatus.failed),
        "Couldn't open Terminal. Install Homebrew from https://brew.sh, then "
        'press Continue.',
      );
      return;
    }
    state = const EngineSetupAwaitingHomebrew(
      EngineSetupProgress(brew: StepStatus.running),
    );
  }

  /// Re-checks for Homebrew after the Terminal install, then installs the
  /// engine. Wired to the "Continue" button in [EngineSetupAwaitingHomebrew].
  Future<void> continueSetup() async {
    ref.invalidate(homebrewInstalledProvider);
    if (!ref.read(homebrewInstalledProvider)) {
      state = const EngineSetupAwaitingHomebrew(
        EngineSetupProgress(brew: StepStatus.running),
        note: "Homebrew isn't detected yet. Finish the install in Terminal, "
            'then press Continue.',
      );
      return;
    }
    await _installEngineStep(const EngineSetupProgress(brew: StepStatus.done));
  }

  /// Re-opens the Homebrew installer in Terminal (e.g. the user closed the
  /// window). Wired to the "Reopen Terminal" button.
  Future<void> reopenTerminal() =>
      ref.read(hostShellServiceProvider).openTerminal(_brewInstallCommand);

  Future<void> _installEngineStep(EngineSetupProgress base) async {
    var progress = base.copyWith(engine: StepStatus.running);
    state = EngineSetupRunning(progress);
    final error = await _installEngine((line) {
      progress = progress.copyWith(log: _appended(progress.log, line));
      state = EngineSetupRunning(progress);
    });
    if (error != null) {
      state = EngineSetupFailed(progress.copyWith(engine: StepStatus.failed), error);
      return;
    }
    ref.invalidate(engineStatusProvider);
    state = const EngineSetupDone();
  }

  /// Installs the llama.cpp engine via grid. Returns null on success, else a
  /// user-facing error message.
  Future<String?> _installEngine(void Function(String) onLine) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) return 'grid executable not found.';
    final process = await service.start(['engine', 'install', 'llama.cpp']);
    _gridProcess = process;
    String? last;
    final sub = process.lines.listen((line) {
      last = line.text;
      onLine(line.text);
    });
    final exit = await process.exitCode;
    await sub.cancel();
    _gridProcess = null;
    if (exit != 0) return last ?? 'Engine install failed (code $exit).';
    return null;
  }

  List<String> _appended(List<String> log, String line) {
    final next = [...log, line];
    if (next.length > _maxLogLines) {
      next.removeRange(0, next.length - _maxLogLines);
    }
    return List.unmodifiable(next);
  }
}
