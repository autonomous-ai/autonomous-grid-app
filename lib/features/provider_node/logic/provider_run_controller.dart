import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../network/logic/grid_sync_controller.dart';
import 'backend_detector.dart';
import 'free_port.dart';

/// Inference backends found on the machine (Ollama, LM Studio, llama.cpp).
final backendsProvider =
    FutureProvider<List<DetectedBackend>>((ref) => BackendDetector().detect());

/// How the built-in engine's local port is chosen — a free OS-assigned port by
/// default, overridable in tests. See [findFreePort] for why we don't rely on
/// the CLI's fixed 8081 default.
final freePortFinderProvider = Provider<FreePortFinder>((_) => findFreePort);

final providerRunControllerProvider =
    NotifierProvider<ProviderRunController, ProviderRunState>(
        ProviderRunController.new);

/// What the running engine is serving (gguf or remote model id), or null when
/// nothing is serving. Lets the model manager refuse to delete a model in use.
final servingModelProvider = Provider<String?>((ref) {
  final state = ref.watch(providerRunControllerProvider);
  return state is ProviderRunActive ? state.model : null;
});

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

/// Provider process is up, serving [grid]; [log] holds the latest streamed
/// lines. [starting] is true until the first line arrives. [grid] lets the UI
/// show "Engine running" only on the network actually being served. [model] is
/// what's being served — the `--serve` gguf for the built-in engine, the remote
/// model id for an external one — so the model manager can refuse to delete a
/// gguf that's in use. Null when unknown (e.g. an engine adopted on restart
/// whose run record carried no model).
class ProviderRunActive extends ProviderRunState {
  const ProviderRunActive({
    required this.grid,
    required this.log,
    required this.starting,
    this.model,
  });
  final String grid;
  final List<String> log;
  final bool starting;
  final String? model;
}

class ProviderRunStopped extends ProviderRunState {
  const ProviderRunStopped();
}

class ProviderRunFailed extends ProviderRunState {
  const ProviderRunFailed(this.message);
  final String message;
}

/// Runs an engine on a grid with `grid join`, streaming its startup log.
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

  /// Grids already reconciled this session, so [reconcile] runs once per grid
  /// even though the view may call it on every rebuild.
  final Set<String> _reconciledGrids = {};

  @override
  ProviderRunState build() {
    ref.onDispose(_teardown);
    return const ProviderRunIdle();
  }

  /// Adopt an engine that's still serving [gridId] — e.g. one whose detached
  /// `grid join` process outlived an app restart — so the UI shows "Engine
  /// running" with a working Stop, instead of an idle start form whose join fails
  /// with "already joined". Reads the CLI's own run record under `~/.grid`; only
  /// adopts a record whose process is still alive. Idempotent per grid, and never
  /// clobbers an in-session run.
  void reconcile(String gridId) {
    if (!_reconciledGrids.add(gridId)) return;
    if (state is! ProviderRunIdle) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) return;

    final store = ref.read(gridHomeStoreProvider);
    final record = store.readEngineRun(gridId, _engineName);
    if (record == null || !_pidIsAlive(record.pid)) return;

    _service = service;
    _grid = gridId;
    final log = store.readEngineRunLog(gridId, _engineName, maxLines: _maxLogLines);
    state = ProviderRunActive(
      grid: gridId,
      starting: false,
      // The record stores the advertised model name(s); good enough for the
      // model manager's in-use guard (lenient match against the gguf).
      model: record.models.isEmpty ? null : record.models.join(', '),
      log: log.isNotEmpty
          ? List.unmodifiable(log)
          : ['Resumed — engine serving ${record.models.join(', ')} on this grid.'],
    );
  }

  /// Serve a model already pulled into `~/.grid/models` via the built-in engine
  /// (`grid join <grid> --serve <gguf> --endpoint-port <free> [--advertise-as]`).
  ///
  /// Picks a free local port for the engine's server instead of the CLI's fixed
  /// 8081 default, which another app on the user's machine may already hold —
  /// otherwise the join aborts with "Port 8081 already in use". [buildArgs] picks
  /// a *fresh* free port each call so [_start] can retry on a new port if it
  /// loses the race for the first one.
  Future<void> startLocal({
    required String network,
    required String model,
    String? advertiseAs,
  }) async {
    Future<List<String>> buildArgs() async => [
          'join', network,
          '--serve', model,
          '--endpoint-port', '${await ref.read(freePortFinderProvider)()}',
          ..._advertiseArgs(advertiseAs),
          '--name', _engineName,
        ];
    return _start(
      await buildArgs(),
      grid: network,
      model: model,
      rebuildForPortConflict: buildArgs,
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
      model: model,
    );
  }

  List<String> _advertiseArgs(String? advertiseAs) =>
      (advertiseAs != null && advertiseAs.isNotEmpty)
          ? ['--advertise-as', advertiseAs]
          : const [];

  /// [rebuildForPortConflict] (local engine only) rebuilds the join args with a
  /// freshly-picked port, so a "port already in use" abort self-heals on a
  /// second port instead of failing.
  Future<void> _start(List<String> args,
      {required String grid,
      String? model,
      bool retried = false,
      Future<List<String>> Function()? rebuildForPortConflict}) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ProviderRunFailed('grid executable not found.');
      return;
    }

    // Only one engine at a time: an engine still serving a *different* grid
    // would be orphaned (it keeps serving via the relay, untracked) once we
    // rebind to the new grid below — so leave it first. Skipped on the retry
    // pass (same grid) so the "already joined" self-heal isn't double-handled.
    if (!retried && _grid != null && _grid != grid) {
      await _leaveEngine(service, _grid!);
    }

    _service = service;
    _grid = grid;
    _stopping = false;
    final log = <String>[];
    state =
        ProviderRunActive(grid: grid, log: const [], starting: true, model: model);

    _process = await service.start(args);
    _process!.lines.listen((line) {
      log.add(line.text);
      if (log.length > _maxLogLines) {
        log.removeRange(0, log.length - _maxLogLines);
      }
      // Still "starting" until `join` exits 0 — the engine serves detached after.
      state = ProviderRunActive(
          grid: grid, log: List.unmodifiable(log), starting: true, model: model);
    });

    final exitCode = await _process!.exitCode;
    _process = null;
    if (_stopping) {
      state = const ProviderRunStopped();
      return;
    }
    if (exitCode == 0) {
      // `grid join` launched the engine in the background; it's serving now.
      state = ProviderRunActive(
          grid: grid, log: List.unmodifiable(log), starting: false, model: model);
      _syncGridAfterJoin();
      return;
    }

    final failure =
        log.isNotEmpty ? log.last : 'engine failed to start (exit $exitCode).';
    final lowerFailure = failure.toLowerCase();
    // A leftover engine from a previous session blocks the join with the same
    // `--name`. Drop it with `grid leave` and retry once, so the user isn't
    // stuck unable to start (and unable to stop a run the app never tracked).
    if (!retried && lowerFailure.contains('already joined')) {
      await _leaveEngine(service, grid);
      return _start(args, grid: grid, model: model, retried: true);
    }
    // Another process grabbed the chosen port between picking it and the engine
    // binding it. Rebuild the args with a fresh free port and retry once.
    if (!retried &&
        rebuildForPortConflict != null &&
        lowerFailure.contains('already in use')) {
      return _start(await rebuildForPortConflict(),
          grid: grid, model: model, retried: true);
    }
    _grid = null;
    state = ProviderRunFailed(failure);
  }

  /// After a successful join the engine is now advertised on the grid, so
  /// re-run `grid sync` to pull the refreshed grid list/tokens (mirrors the
  /// auto-sync after create/login). Fire-and-forget and best-effort: a sync
  /// hiccup must never disturb a start that already succeeded, and the sync
  /// controller surfaces its own status/expiry handling.
  void _syncGridAfterJoin() {
    unawaited(() async {
      try {
        await ref.read(gridSyncControllerProvider.notifier).sync();
      } on Object {
        // Best-effort refresh; ignore failures here.
      }
    }());
  }

  /// True if [pid] names a live process. POSIX `kill -0` probes existence
  /// without signalling; where it's unavailable we can't tell, so assume alive
  /// (the Stop path `grid leave`s regardless).
  static bool _pidIsAlive(int? pid) {
    if (pid == null) return false;
    if (Platform.isWindows) return true;
    try {
      return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
    } on ProcessException {
      return true;
    }
  }

  /// Stop the engine: `grid leave` unregisters and kills the detached engine.
  Future<void> stop() async {
    _stopping = true;
    _process?.kill();
    final service = _service;
    final grid = _grid;
    _grid = null;
    if (service != null && grid != null) {
      await _leaveEngine(service, grid);
    }
    state = const ProviderRunStopped();
  }

  /// Stop every engine this app may be serving — the one launched/adopted this
  /// session plus any detached engine still recorded under `~/.grid` (e.g. from
  /// a prior session we never reconciled) — then settle back to idle. Called
  /// before sign-out and on app close so no engine keeps serving on the relay
  /// without the app to manage it. Best-effort and time-boxed: a hung or failed
  /// `grid leave` can't block quitting or signing out.
  Future<void> shutdownServing() async {
    _stopping = true;
    _process?.kill();
    _process = null;

    final service = ref.read(gridCliServiceProvider);
    if (service != null) {
      final grids = <String>{
        if (_grid != null) _grid!,
        ...ref.read(gridHomeStoreProvider).listServingGrids(_engineName),
      };
      for (final grid in grids) {
        try {
          await _leaveEngine(service, grid).timeout(const Duration(seconds: 6));
        } on Object {
          // Best-effort: a failed/slow leave must not block the caller.
        }
      }
    }

    _grid = null;
    _reconciledGrids.clear();
    state = const ProviderRunIdle();
  }

  /// On dispose, leave any still-serving detached engine so none is left behind
  /// (best-effort; dispose can't await).
  void _teardown() {
    _process?.kill();
    final service = _service;
    final grid = _grid;
    _grid = null;
    if (service != null && grid != null) {
      unawaited(_leaveEngine(service, grid));
    }
  }

  /// `grid leave <grid> --engine grid-app` — unregisters and kills the detached
  /// engine serving [grid]. One place so every stop path stays consistent.
  Future<void> _leaveEngine(GridCliService service, String grid) =>
      service.run(['leave', grid, '--engine', _engineName]);
}
