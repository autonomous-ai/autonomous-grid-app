import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'engine_status.dart';

/// State of the built-in-engine setup flow.
///
/// It is a single step now: `grid engine install llama.cpp` downloads a pinned
/// official build into `~/.grid`. It used to install Homebrew first — which a
/// GUI app cannot do (Homebrew's installer needs an interactive `sudo`), so the
/// flow had to hand off to Terminal and ask the user to type their password.
/// Nothing here needs a package manager or admin rights any more.
sealed class EngineSetupState {
  const EngineSetupState();
}

/// Nothing running yet — the initial state and where a fresh flow starts.
class EngineSetupIdle extends EngineSetupState {
  const EngineSetupIdle();
}

/// The install is streaming; [log] is its latest output.
class EngineSetupRunning extends EngineSetupState {
  const EngineSetupRunning(this.log);
  final List<String> log;
}

/// The engine is installed and ready to serve a model.
class EngineSetupDone extends EngineSetupState {
  const EngineSetupDone();
}

/// The install failed. [message] is user-facing; [log] keeps the detail.
class EngineSetupFailed extends EngineSetupState {
  const EngineSetupFailed(this.log, this.message);
  final List<String> log;
  final String message;
}

final engineSetupControllerProvider =
    NotifierProvider<EngineSetupController, EngineSetupState>(
      EngineSetupController.new,
    );

/// Installs the built-in engine by running `grid engine install llama.cpp` and
/// streaming its output.
class EngineSetupController extends Notifier<EngineSetupState> {
  static const _maxLogLines = 300;

  GridProcess? _gridProcess;

  @override
  EngineSetupState build() {
    ref.onDispose(() => _gridProcess?.kill());
    return const EngineSetupIdle();
  }

  /// Starts (or retries) the install.
  Future<void> run() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const EngineSetupFailed(
        [],
        "Grid isn't ready yet. Restart the app and try again.",
      );
      return;
    }

    var log = const <String>[];
    state = EngineSetupRunning(log);

    final process = await service.start(['engine', 'install', 'llama.cpp']);
    _gridProcess = process;

    String? last;
    final subscription = process.lines.listen((line) {
      last = line.text;
      log = _appended(log, line.text);
      state = EngineSetupRunning(log);
    });

    final exit = await process.exitCode;
    await subscription.cancel();
    _gridProcess = null;

    if (exit != 0) {
      state = EngineSetupFailed(
        log,
        last ?? 'The engine could not be installed (code $exit).',
      );
      return;
    }
    ref.invalidate(engineStatusProvider);
    state = const EngineSetupDone();
  }

  List<String> _appended(List<String> log, String line) {
    final next = [...log, line];
    if (next.length > _maxLogLines) {
      next.removeRange(0, next.length - _maxLogLines);
    }
    return List.unmodifiable(next);
  }
}
