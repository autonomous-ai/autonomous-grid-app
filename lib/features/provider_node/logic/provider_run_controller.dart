import 'dart:async';

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

/// Base URL of the locally-running provider's OpenAI-compatible server, parsed
/// from its run log (e.g. `http://localhost:8081`). Null when no local provider
/// is serving or the port can't be read yet. Lets the Playground hit the local
/// server directly over HTTP for a quick smoke test.
final localProviderEndpointProvider = Provider<String?>((ref) {
  final state = ref.watch(providerRunControllerProvider);
  if (state is! ProviderRunActive) return null;
  final port = _parseLocalPort(state.log);
  return port == null ? null : 'http://localhost:$port';
});

/// `127.0.0.1:8081` / `localhost:8081` in httpx log lines, or the
/// `llama_llm_8081.log` filename the provider prints on spawn.
final _localPortPattern =
    RegExp(r'(?:localhost|127\.0\.0\.1):(\d{2,5})|llama_\w*?(\d{2,5})\.log');

int? _parseLocalPort(List<String> log) {
  for (final line in log.reversed) {
    final match = _localPortPattern.firstMatch(line);
    if (match == null) continue;
    final port = match.group(1) ?? match.group(2);
    final parsed = port == null ? null : int.tryParse(port);
    if (parsed != null) return parsed;
  }
  return null;
}

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

/// Shares a model to a grid with `grid join`, streaming its startup log.
///
/// Unlike the old foreground `provider start`, `grid join` spawns the engine as a
/// **detached** background process and returns once it's launched — so a clean
/// exit (0) means "now serving", not "stopped". The engine keeps running via the
/// relay until we `grid leave` it, which [stop] (and dispose) do so no engine is
/// left behind. We pass a fixed `--name` so `grid leave --engine` can target it.
///
/// TODO(BE): the detached engine logs to `~/.grid/run/engines/...`, not through
/// this process, so the streamed log is just `join`'s startup lines and the
/// Playground's local-port auto-detection ([localProviderEndpointProvider]) no
/// longer fires — consumers fall back to the relay chat path.
class ProviderRunController extends Notifier<ProviderRunState> {
  static const _maxLogLines = 400;

  /// Stable engine id passed via `--name`, so [stop] can target it with
  /// `grid leave --engine`. Namespaced per grid by the CLI's run records.
  static const _engineName = 'grid-app';

  GridProcess? _process;
  GridCliService? _service;
  String? _grid;
  bool _stopping = false;

  @override
  ProviderRunState build() {
    ref.onDispose(_teardown);
    return const ProviderRunIdle();
  }

  /// Serve a model already pulled into `~/.grid/models` via the built-in engine
  /// (`grid join <grid> --serve <gguf> [--advertise-as]`).
  Future<void> startLocal({
    required String network,
    required String model,
    String? advertiseAs,
  }) {
    return _start(
      [
        'join', network,
        '--serve', model,
        ..._advertiseArgs(advertiseAs),
        '--name', _engineName,
      ],
      grid: network,
    );
  }

  /// Serve from an external OpenAI-compatible endpoint
  /// (`grid join <grid> --at <url> -m <model>`).
  Future<void> startExternal({
    required String network,
    required String endpoint,
    required String model,
    String? advertiseAs,
  }) {
    return _start(
      [
        'join', network,
        '--at', endpoint,
        '-m', model,
        ..._advertiseArgs(advertiseAs),
        '--name', _engineName,
      ],
      grid: network,
    );
  }

  List<String> _advertiseArgs(String? advertiseAs) =>
      (advertiseAs != null && advertiseAs.isNotEmpty)
          ? ['--advertise-as', advertiseAs]
          : const [];

  Future<void> _start(List<String> args, {required String grid}) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ProviderRunFailed('grid executable not found.');
      return;
    }

    _service = service;
    _grid = grid;
    _stopping = false;
    final log = <String>[];
    state = const ProviderRunActive(log: [], starting: true);

    _process = await service.start(args);
    _process!.lines.listen((line) {
      log.add(line.text);
      if (log.length > _maxLogLines) {
        log.removeRange(0, log.length - _maxLogLines);
      }
      // Still "starting" until `join` exits 0 — the engine serves detached after.
      state = ProviderRunActive(log: List.unmodifiable(log), starting: true);
    });

    final exitCode = await _process!.exitCode;
    _process = null;
    if (_stopping) {
      state = const ProviderRunStopped();
      return;
    }
    if (exitCode == 0) {
      // `grid join` launched the engine in the background; it's serving now.
      state = ProviderRunActive(log: List.unmodifiable(log), starting: false);
      return;
    }
    _grid = null;
    state = ProviderRunFailed(
        log.isNotEmpty ? log.last : 'sharing failed to start (exit $exitCode).');
  }

  /// Stop sharing: `grid leave` unregisters and kills the detached engine.
  Future<void> stop() async {
    _stopping = true;
    _process?.kill();
    final service = _service;
    final grid = _grid;
    _grid = null;
    if (service != null && grid != null) {
      await service.run(['leave', grid, '--engine', _engineName]);
    }
    state = const ProviderRunStopped();
  }

  /// On dispose, leave any still-serving detached engine so none is left behind
  /// (best-effort; dispose can't await).
  void _teardown() {
    _process?.kill();
    final service = _service;
    final grid = _grid;
    _grid = null;
    if (service != null && grid != null) {
      unawaited(service.run(['leave', grid, '--engine', _engineName]));
    }
  }
}
