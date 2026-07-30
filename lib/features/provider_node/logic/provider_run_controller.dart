import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/state/models/engine_run.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_sync_controller.dart';
import 'api_engine_catalog.dart';
import 'backend_detector.dart';
import 'engine_liveness.dart';
import 'free_port.dart';
import 'node_name.dart';
import 'serving_engines_provider.dart';

/// Inference backends found on the machine (Ollama, LM Studio, llama.cpp).
final backendsProvider = FutureProvider<List<DetectedBackend>>(
  (ref) => BackendDetector().detect(),
);

/// How the built-in engine's local port is chosen — a free OS-assigned port by
/// default, overridable in tests. See [findFreePort] for why we don't rely on
/// the CLI's fixed 8081 default.
final freePortFinderProvider = Provider<FreePortFinder>((_) => findFreePort);

/// How long to wait after a successful join before re-syncing the grid list.
/// Gives the just-joined engine a moment to register on the grid so the sync
/// reflects it; overridable in tests to run without the real delay.
final syncDelayAfterJoinProvider = Provider<Duration>(
  (_) => const Duration(seconds: 5),
);

/// Cap on any `grid leave` wait so a hung/slow relay can never strand the UI on
/// "Engine running" (or block sign-out/quit). Shared by [ProviderRunController]'s
/// stop and shutdown paths; overridable in tests to avoid a real multi-second
/// wait.
final leaveTimeoutProvider = Provider<Duration>(
  (_) => const Duration(seconds: 6),
);

/// The name this machine joins a grid under (the node name on the grid page and
/// the stable engine id for stop/reconcile) — the machine's own name via
/// [deriveNodeName], so two machines don't both show as "grid-app". Overridable
/// in tests for a deterministic id. See [deriveNodeName].
final nodeNameProvider = Provider<String>(
  (_) => deriveNodeName(Platform.localHostname),
);

final providerRunControllerProvider =
    NotifierProvider<ProviderRunController, ProviderRunState>(
      ProviderRunController.new,
    );

/// Every model this machine is serving on the active grid — the union across all
/// its engines, joined for display. Null when nothing is serving. Lets the model
/// manager refuse to delete a gguf that's in use (lenient substring match).
final servingModelProvider = Provider<String?>((ref) {
  final models = [
    for (final engine in ref.watch(servingEnginesProvider)) ...engine.models,
  ];
  return models.isEmpty ? null : models.join(', ');
});

/// Base URL of this machine's local built-in engine on the active grid, read
/// from its run record's `endpoint_port`. Null when no local engine is serving.
/// Lets the Playground hit the local server directly for a quick smoke test.
final localProviderEndpointProvider = Provider<String?>((ref) {
  ref.watch(engineUnionRefreshProvider);
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return null;
  final record = firstLiveRun(
    ref.read(gridHomeStoreProvider).listEngineRuns(network.networkId),
  );
  if (record == null) return null;
  final hasLocal = record.engines.any((e) => e.kind == EngineKind.local);
  final port = record.endpointPort;
  if (!hasLocal || port == null) return null;
  return 'http://localhost:$port';
});

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

/// A stop is under way on [grid] — `grid leave` unregisters the engine with the
/// relay and kills it, which takes seconds and is time-boxed at
/// [leaveTimeoutProvider].
///
/// Its own state because that gap used to show nothing at all: the row kept its
/// green dot and its live Stop, so the only feedback was that clicking again did
/// nothing. The engine is still serving until this resolves, so the UI says
/// "Stopping", not "Stopped".
class ProviderRunStopping extends ProviderRunState {
  const ProviderRunStopping(this.grid);

  final String grid;
}

class ProviderRunStopped extends ProviderRunState {
  const ProviderRunStopped();
}

class ProviderRunFailed extends ProviderRunState {
  const ProviderRunFailed(this.message, {this.model});
  final String message;

  /// What the failed start was trying to serve — the `--serve` gguf, the API
  /// kind, or the external model id. Null when the attempt never got far enough
  /// to know (e.g. the CLI itself was missing). Lets the failure card name the
  /// engine that broke instead of a bare "the local engine".
  final String? model;
}

/// Runs an engine on a grid with `grid join`, streaming its startup log.
///
/// Unlike the old foreground `provider start`, `grid join` spawns the engine as a
/// **detached** background process and returns once it's launched — so a clean
/// exit (0) means "now serving", not "stopped". The engine keeps running via the
/// relay until we `grid leave` it, which [stop] (and dispose) do so no engine is
/// left behind. We pass a fixed `--name` as the node's display name on the grid.
///
/// TODO(BE): the detached engine logs to `~/.grid/run/engines/...`, not through
/// this process, so the streamed log is just `join`'s startup lines and the
/// Playground's local-port auto-detection ([localProviderEndpointProvider]) no
/// longer fires — consumers fall back to the relay chat path.
class ProviderRunController extends Notifier<ProviderRunState> {
  static const _maxLogLines = 400;

  /// The node's display name on the grid, passed via `--name` on join so each
  /// host appears as itself on the grid page instead of a shared "grid-app".
  /// The machine's own name (via [nodeNameProvider]); read once — it's stable
  /// for the app's lifetime. Purely cosmetic: the CLI keys run records and
  /// `grid leave` by its own engine id, not this name (see [_leaveEngine]).
  late final String _engineName = ref.read(nodeNameProvider);

  /// Context window for an external (`--at`) engine, passed via `--ctx-size`.
  /// There's no local GGUF to inspect for the real maximum, so we send a fixed
  /// 200k — the local `--serve` path derives its own from `grid ctx` instead.
  static const _externalCtxSize = 200000;

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
    final record = firstLiveRun(store.listEngineRuns(gridId));
    if (record == null) return;

    _service = service;
    _grid = gridId;
    final log = store.readEngineRunLog(
      gridId,
      record.engineId,
      maxLines: _maxLogLines,
    );
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
    // The union list reads the same record from disk; nudge it now the adopted
    // engine is known so the serving list reflects it on restart.
    _bumpUnion();
  }

  /// Invalidate [servingEnginesProvider] after a roster change — the store is a
  /// plain reader, so the list only re-reads disk when this ticks.
  void _bumpUnion() => ref.read(engineUnionRefreshProvider.notifier).bump();

  /// Dismiss a [ProviderRunFailed] so the add-engine forms come back, without
  /// touching any engine. Only clears that state: a failure is a dead end the
  /// user has now read, whereas idle/active/stopped all describe something real
  /// that a dismissal must not overwrite.
  void clearFailure() {
    if (state is ProviderRunFailed) state = const ProviderRunIdle();
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
    int? ctxSize,
  }) async {
    Future<List<String>> buildArgs() async => [
      'join',
      network,
      '--serve',
      model,
      '--endpoint-port',
      '${await ref.read(freePortFinderProvider)()}',
      ..._advertiseArgs(advertiseAs),
      ..._ctxArgs(ctxSize),
      '--name',
      _engineName,
    ];
    return _start(
      await buildArgs(),
      grid: network,
      model: model,
      rebuildForPortConflict: buildArgs,
    );
  }

  /// Serve from an external OpenAI-compatible endpoint
  /// (`grid join <grid> --at <url> -m <model> --ctx-size <n>`).
  Future<void> startExternal({
    required String network,
    required String endpoint,
    required String model,
    String? advertiseAs,
  }) {
    return _start(
      [
        'join',
        network,
        '--at',
        endpoint,
        '-m',
        model,
        ..._advertiseArgs(advertiseAs),
        ..._ctxArgs(_externalCtxSize),
        '--name',
        _engineName,
      ],
      grid: network,
      model: model,
    );
  }

  /// Serve a third-party hosted engine to the active remote grid (this app is
  /// always remote-only), via
  /// `grid join <grid> --api <kind> [-m <model> …]`.
  ///
  /// For a key-based provider, the key travels in [environment]
  /// (`<KIND>_API_KEY`), not in argv, so it never reaches a log — the CLI reads
  /// it there first, validates it against the vendor, then stores it for the
  /// detached serve loop to reuse (ADR 0012). Pass an empty [apiKey] to fall back
  /// to that stored key.
  ///
  /// For a **CLI seat** ([ApiAuth.localCli]) nothing is passed at all: the join
  /// starts a loopback server that drives the coding CLI on this computer, and
  /// that CLI's own sign-in is the credential — the grid holds none. The seat's
  /// pacing (one process per request, its own quota ceilings) is left at the
  /// CLI's defaults: this is the operator's personal subscription, and the app
  /// has no business widening it without being asked.
  ///
  /// [models] are advertised whitelist names (`openai:gpt-5.5`); empty serves
  /// the whole set the credential can see (the CLI's zero-config default). No
  /// `--advertise-as`/`--ctx-size`: the CLI rejects aliasing for API engines and
  /// the vendor owns the context window.
  Future<void> startApiEngine({
    required String network,
    required ApiProvider provider,
    required String apiKey,
    List<String> models = const [],
  }) {
    final envVar = provider.envVar;
    return _start(
      [
        'join',
        network,
        '--api',
        provider.kind,
        for (final model in models) ...['-m', model],
        '--name',
        _engineName,
      ],
      grid: network,
      model: models.isEmpty ? provider.kind : models.join(', '),
      environment: (envVar != null && apiKey.isNotEmpty)
          ? {envVar: apiKey}
          : null,
    );
  }

  List<String> _advertiseArgs(String? advertiseAs) =>
      (advertiseAs != null && advertiseAs.isNotEmpty)
      ? ['--advertise-as', advertiseAs]
      : const [];

  /// `--ctx-size <n>` when a context length is set, else nothing (the engine
  /// uses its own default). Shared by the local and external join paths.
  List<String> _ctxArgs(int? ctxSize) =>
      ctxSize != null ? ['--ctx-size', '$ctxSize'] : const [];

  /// [rebuildForPortConflict] (local engine only) rebuilds the join args with a
  /// freshly-picked port, so a "port already in use" abort self-heals on a
  /// second port instead of failing.
  Future<void> _start(
    List<String> args, {
    required String grid,
    String? model,
    bool retried = false,
    Map<String, String>? environment,
    Future<List<String>> Function()? rebuildForPortConflict,
  }) async {
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
    state = ProviderRunActive(
      grid: grid,
      log: const [],
      starting: true,
      model: model,
    );

    _process = await service.start(args, environment: environment);
    _process!.lines.listen((line) {
      // The user cancelled (or stopped) this run. `kill()` is a request, not an
      // instant: the CLI keeps flushing buffered lines on its way out, and each
      // one used to re-arm "Starting…" — so seconds after cancelling, the
      // section reappeared on its own and then vanished again when the process
      // finally exited. Nothing this run says now can change what was decided.
      if (_stopping) return;
      log.add(line.text);
      if (log.length > _maxLogLines) {
        log.removeRange(0, log.length - _maxLogLines);
      }
      // Still "starting" until `join` exits 0 — the engine serves detached after.
      state = ProviderRunActive(
        grid: grid,
        log: List.unmodifiable(log),
        starting: true,
        model: model,
      );
    });

    final exitCode = await _process!.exitCode;
    _process = null;
    if (_stopping) {
      // [stop] owns the ending: it holds "Stopping…" until `grid leave` comes
      // back, which takes seconds. Settling to Stopped the moment the killed
      // process exits cut that short and dropped the section off the page while
      // the leave was still running.
      if (state is! ProviderRunStopping) state = const ProviderRunStopped();
      return;
    }
    if (exitCode == 0) {
      // `grid join` launched the engine in the background; it's serving now and
      // has joined the machine's union — refresh the serving list to include it.
      state = ProviderRunActive(
        grid: grid,
        log: List.unmodifiable(log),
        starting: false,
        model: model,
      );
      _bumpUnion();
      _syncGridSoon();
      return;
    }

    final failure = log.isNotEmpty
        ? log.last
        : 'engine failed to start (exit $exitCode).';
    final lowerFailure = failure.toLowerCase();
    // A leftover engine from a previous session blocks the join with the same
    // `--name`. Drop it with `grid leave` and retry once, so the user isn't
    // stuck unable to start (and unable to stop a run the app never tracked).
    if (!retried && lowerFailure.contains('already joined')) {
      await _leaveEngine(service, grid);
      return _start(
        args,
        grid: grid,
        model: model,
        retried: true,
        environment: environment,
      );
    }
    // Another process grabbed the chosen port between picking it and the engine
    // binding it. Rebuild the args with a fresh free port and retry once.
    if (!retried &&
        rebuildForPortConflict != null &&
        lowerFailure.contains('already in use')) {
      return _start(
        await rebuildForPortConflict(),
        grid: grid,
        model: model,
        retried: true,
        environment: environment,
      );
    }
    _grid = null;
    // Both sides of this: upstream's humanized message, and the model the
    // failure card needs to name which engine broke.
    state = ProviderRunFailed(_humanizeJoinFailure(failure), model: model);
  }

  /// Turn a raw `grid join` failure into a line a user can act on. The commonest
  /// dead-end is trying to share on a grid you're only a consumer of — the relay
  /// rejects the register with a missing `provider:*` scope. Anything we don't
  /// recognise passes through unchanged (the Debug/command log keeps the raw).
  ///
  /// A **CLI seat** that isn't signed in is left alone on purpose: the CLI's own
  /// line already names the exact command to run (`claude auth login`, and where
  /// the seat keeps its sign-in), and rewriting it here could only make it vaguer
  /// while going stale the moment a vendor renames the command.
  static String _humanizeJoinFailure(String raw) {
    final lower = raw.toLowerCase();
    final isProviderScope =
        lower.contains('provider:update') ||
        lower.contains('provider:submit') ||
        (lower.contains('scope') && lower.contains('provider'));
    if (isProviderScope) {
      return "You can't add a model to this grid — only its providers can. Ask "
          'whoever runs it to let you share, or switch to a grid you own.';
    }
    return raw;
  }

  /// Re-run `grid sync` a moment after the engine roster changes — a join or a
  /// leave — to pull the refreshed grid list/tokens so the UI reflects the
  /// engine appearing or disappearing (mirrors the auto-sync after
  /// create/login). Fire-and-forget and best-effort: a sync hiccup must never
  /// disturb the action that already succeeded, and the sync controller surfaces
  /// its own status/expiry handling. Delayed so the relay has registered (or
  /// deregistered) the engine before we re-read.
  void _syncGridSoon() {
    final delay = ref.read(syncDelayAfterJoinProvider);
    unawaited(() async {
      await Future<void>.delayed(delay);
      try {
        await ref.read(gridSyncControllerProvider.notifier).sync();
      } on Object {
        // Best-effort refresh; ignore failures here (incl. a disposed ref if the
        // controller was torn down during the delay).
      }
    }());
  }

  /// Drop one engine from this machine's union on [grid] with a scoped
  /// `grid leave --engine`, leaving the rest serving. The CLI hot-reloads the
  /// reduced union (or tears the identity down if it was the last engine).
  /// Best-effort and time-boxed like [stop]; the union list re-reads the true
  /// roster from disk afterwards either way.
  Future<void> removeEngine(String grid, String selector) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) return;
    final wasServing = state;
    state = ProviderRunStopping(grid);
    try {
      await service
          .run(['leave', grid, '--engine', selector])
          .timeout(ref.read(leaveTimeoutProvider));
    } on Object {
      // A slow/failed leave must not strand the UI; the refresh below re-reads
      // the real roster, so a no-op leave simply leaves the row in place.
    }
    _bumpUnion();
    // Disk decides what we settle on, not the leave's exit: it may have been a
    // no-op. Nothing left on this grid means this machine has stopped serving;
    // anything left (a legacy multi-engine record) is still the run we were in.
    final stillServing = firstLiveRun(
      ref.read(gridHomeStoreProvider).listEngineRuns(grid),
    );
    state = stillServing == null ? const ProviderRunStopped() : wasServing;
    _syncGridSoon();
  }

  /// Stop the engine: `grid leave` unregisters and kills the detached engine.
  /// Time-boxed and best-effort so a hung leave still lands the UI on
  /// "Stopped" instead of stranding it on "Engine running".
  Future<void> stop() async {
    _stopping = true;
    _process?.kill();
    _process = null;
    final service = _service;
    final grid = _grid;
    _grid = null;
    if (grid != null) state = ProviderRunStopping(grid);
    if (service != null && grid != null) {
      try {
        await _leaveEngine(
          service,
          grid,
        ).timeout(ref.read(leaveTimeoutProvider));
      } on Object {
        // A slow/failed leave must not block the Stop action's UI settling.
      }
      // The engine has left, so re-sync the grid list/state — same as after a
      // join — so the UI stops showing it as serving.
      _syncGridSoon();
    }
    _bumpUnion();
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
        ?_grid,
        ...ref.read(gridHomeStoreProvider).listServingGrids(),
      };
      for (final grid in grids) {
        try {
          await _leaveEngine(
            service,
            grid,
          ).timeout(ref.read(leaveTimeoutProvider));
        } on Object {
          // Best-effort: a failed/slow leave must not block the caller.
        }
      }
    }

    _grid = null;
    _reconciledGrids.clear();
    _bumpUnion();
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

  /// `grid leave <grid>` — tears down this machine's engine identity on [grid],
  /// stopping the detached `grid join` engine (and reaping any legacy sibling run
  /// record). One place so every stop path stays consistent.
  ///
  /// No `--engine` filter, on purpose: in remote mode the CLI keys the run record
  /// by a fixed engine id (`remote`), not our `--name` — which it stores only as
  /// the display `meta_name` — and `grid leave --engine` matches by endpoint URL,
  /// served model or label, never by name. Passing `--engine <name>` therefore
  /// matched nothing and left the engine serving on the relay after the app
  /// closed. A bare leave targets the grid's single identity, which in this
  /// remote-only app is exactly the engine we started.
  Future<void> _leaveEngine(GridCliService service, String grid) =>
      service.run(['leave', grid]);
}
