import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'engine_status.dart';

/// Detected engine status. Invalidate after an install to rescan.
final engineStatusProvider =
    Provider<EngineStatus>((ref) => EngineDetector().detect());

final llamaInstallControllerProvider =
    NotifierProvider<LlamaInstallController, LlamaInstallState>(
        LlamaInstallController.new);

sealed class LlamaInstallState {
  const LlamaInstallState();
}

class LlamaInstallIdle extends LlamaInstallState {
  const LlamaInstallIdle();
}

/// Install in progress; [log] holds the latest streamed lines.
class LlamaInstalling extends LlamaInstallState {
  const LlamaInstalling(this.log);
  final List<String> log;
}

class LlamaInstallDone extends LlamaInstallState {
  const LlamaInstallDone();
}

class LlamaInstallFailed extends LlamaInstallState {
  const LlamaInstallFailed(this.message);
  final String message;
}

/// Runs `grid llama.cpp install`, streaming its log, and re-detects the engine
/// on success. On Apple Silicon this drives Homebrew; on Linux a CUDA tarball
/// or source build.
class LlamaInstallController extends Notifier<LlamaInstallState> {
  static const _maxLogLines = 300;
  GridProcess? _process;

  @override
  LlamaInstallState build() {
    ref.onDispose(() => _process?.kill());
    return const LlamaInstallIdle();
  }

  Future<void> install() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const LlamaInstallFailed('grid executable not found.');
      return;
    }

    final log = <String>[];
    state = const LlamaInstalling([]);

    _process = await service.start(['llama.cpp', 'install']);
    _process!.lines.listen((line) {
      log.add(line.text);
      if (log.length > _maxLogLines) log.removeRange(0, log.length - _maxLogLines);
      state = LlamaInstalling(List.unmodifiable(log));
    });

    final exitCode = await _process!.exitCode;
    if (exitCode == 0) {
      ref.invalidate(engineStatusProvider);
      state = const LlamaInstallDone();
      return;
    }
    state = LlamaInstallFailed(
      log.isNotEmpty ? log.last : 'llama.cpp install failed (exit $exitCode).',
    );
  }
}
