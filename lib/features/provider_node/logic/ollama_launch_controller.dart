import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';
import 'backend_detector.dart';
import 'provider_run_controller.dart' show backendsProvider;

final ollamaLaunchControllerProvider =
    NotifierProvider<OllamaLaunchController, OllamaLaunchState>(
      OllamaLaunchController.new,
    );

/// States of the "Run Ollama" action.
sealed class OllamaLaunchState {
  const OllamaLaunchState();
}

class OllamaLaunchIdle extends OllamaLaunchState {
  const OllamaLaunchIdle();
}

class OllamaLaunchStarting extends OllamaLaunchState {
  const OllamaLaunchStarting();
}

class OllamaLaunchFailed extends OllamaLaunchState {
  const OllamaLaunchFailed(this.message);
  final String message;
}

/// Starts a locally-installed Ollama that isn't serving yet, waits for its API
/// to come online, then refreshes the detected-backends list so its card flips
/// from "Run Ollama" to the ready-to-serve form. Best-effort: launching a
/// third-party app/binary can fail in ways we can't fully predict, so failures
/// map to a plain-language message instead of throwing into the UI.
class OllamaLaunchController extends Notifier<OllamaLaunchState> {
  static const _base = 'http://localhost:11434/v1';

  @override
  OllamaLaunchState build() => const OllamaLaunchIdle();

  Future<void> start() async {
    if (state is OllamaLaunchStarting) return;
    state = const OllamaLaunchStarting();

    try {
      await _launch();
    } on Object {
      state = const OllamaLaunchFailed(
        "Couldn't start Ollama automatically. Open the Ollama app yourself, "
        'then try again.',
      );
      return;
    }

    if (!await _waitUntilReady()) {
      state = const OllamaLaunchFailed(
        "Ollama is starting but didn't come online in time. Give it a moment, "
        'then reopen this tab.',
      );
      return;
    }

    ref.invalidate(backendsProvider);
    state = const OllamaLaunchIdle();
  }

  /// macOS: launch the menubar app (it owns the server) via `open -a Ollama`,
  /// falling back to the `ollama serve` binary. Elsewhere: start `ollama serve`
  /// detached, on the augmented PATH so a packaged app can find it.
  Future<void> _launch() async {
    if (Platform.isMacOS) {
      final opened = await Process.run('open', ['-a', 'Ollama']);
      if (opened.exitCode == 0) return;
    }
    final bin = BackendDetector.findOnPath('ollama');
    if (bin == null) {
      throw const ProcessException('ollama', ['serve'], 'not found');
    }
    await Process.start(
      bin,
      ['serve'],
      mode: ProcessStartMode.detached,
      environment: {'PATH': HostEnvironment.path()},
    );
  }

  /// Poll the Ollama API for up to ~20s while it boots.
  Future<bool> _waitUntilReady() async {
    for (var i = 0; i < 20; i++) {
      if (await BackendDetector.isServerUp(_base)) return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }
}
