import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import 'backend_detector.dart';

/// Inference backends found on the machine (Ollama, LM Studio, llama.cpp).
final backendsProvider =
    FutureProvider<List<DetectedBackend>>((ref) => BackendDetector().detect());

final providerRunControllerProvider =
    NotifierProvider<ProviderRunController, ProviderRunState>(
        ProviderRunController.new);

sealed class ProviderRunState {
  const ProviderRunState();
}

class ProviderRunIdle extends ProviderRunState {
  const ProviderRunIdle();
}

/// Provider process is up; [log] holds the latest streamed lines. [starting]
/// is true until the first line arrives.
class ProviderRunActive extends ProviderRunState {
  const ProviderRunActive({required this.log, required this.starting});
  final List<String> log;
  final bool starting;
}

class ProviderRunStopped extends ProviderRunState {
  const ProviderRunStopped();
}

class ProviderRunFailed extends ProviderRunState {
  const ProviderRunFailed(this.message);
  final String message;
}

/// Runs `grid provider start` as an app-owned foreground process and streams its
/// log. The process is killed on stop or app dispose (loại 2 in the contract's
/// process model — no zombie llama-server / poll loop left behind).
class ProviderRunController extends Notifier<ProviderRunState> {
  static const _maxLogLines = 400;
  GridProcess? _process;
  bool _stopping = false;

  @override
  ProviderRunState build() {
    ref.onDispose(() => _process?.kill());
    return const ProviderRunIdle();
  }

  /// Start a provider serving from an external OpenAI-compatible endpoint.
  Future<void> startExternal({
    required String network,
    required String endpoint,
    required String model,
    String? advertiseAs,
  }) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ProviderRunFailed('grid executable not found.');
      return;
    }

    _stopping = false;
    final log = <String>[];
    state = const ProviderRunActive(log: [], starting: true);

    final args = <String>[
      'provider', 'start',
      '--network', network,
      '--at', endpoint,
      '--model', model,
      if (advertiseAs != null && advertiseAs.isNotEmpty) ...[
        '--advertise-as',
        advertiseAs,
      ],
    ];

    _process = await service.start(args);
    _process!.lines.listen((line) {
      log.add(line.text);
      if (log.length > _maxLogLines) {
        log.removeRange(0, log.length - _maxLogLines);
      }
      state = ProviderRunActive(log: List.unmodifiable(log), starting: false);
    });

    final exitCode = await _process!.exitCode;
    if (_stopping) {
      state = const ProviderRunStopped();
      return;
    }
    state = exitCode == 0
        ? const ProviderRunStopped()
        : ProviderRunFailed(
            log.isNotEmpty ? log.last : 'provider exited ($exitCode).');
  }

  void stop() {
    _stopping = true;
    _process?.kill();
  }
}
