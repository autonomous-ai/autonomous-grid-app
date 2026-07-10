import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/grid_home_store.dart';
import 'package:grid_app/infrastructure/state/models/engine_run.dart';

const _args = [
  'join', 'net',
  '--at', 'http://x/v1',
  '-m', 'm',
  '--ctx-size', '200000',
  '--name', 'grid-app',
];

/// Stubs the run-state reads so [ProviderRunController.reconcile] and
/// [ProviderRunController.shutdownServing] can be driven without touching
/// `~/.grid`.
class _StubHomeStore extends GridHomeStore {
  _StubHomeStore({this.record, this.log = const [], this.serving = const []});

  final EngineRunRecord? record;
  final List<String> log;
  final List<String> serving;

  /// The engine id [ProviderRunController.reconcile] asked the log for — must be
  /// the record's own id (the CLI's `remote`), never the app's `--name`.
  String? logEngineIdAsked;

  @override
  List<EngineRunRecord> listEngineRuns(String gridId) =>
      record == null ? const [] : [record!];

  @override
  List<String> readEngineRunLog(String gridId, String engineId,
      {int maxLines = 400}) {
    logEngineIdAsked = engineId;
    return log;
  }

  @override
  List<String> listServingGrids() => serving;
}

/// A fake CLI that records every `run` call so tests can assert which engines
/// were left (`grid leave …`).
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

/// A fake CLI whose `grid leave` never returns, so tests can prove the stop
/// paths still settle the UI via their timeout.
class _HangingLeaveCli extends FakeGridCliService {
  @override
  Future<CliResult> run(List<String> args) {
    if (args.isNotEmpty && args.first == 'leave') {
      return Completer<CliResult>().future; // never completes
    }
    return super.run(args);
  }
}

ProviderContainer _containerWith(GridCliService? cli, {GridHomeStore? store}) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(cli),
    nodeNameProvider.overrideWithValue('grid-app'),
    if (store != null) gridHomeStoreProvider.overrideWithValue(store),
  ]);
  return container;
}

void main() {
  test('startExternal streams log then serves on exit 0', () async {
    // `grid join` launches the engine detached and exits 0; the controller then
    // reports "serving" (ProviderRunActive, not starting), not stopped.
    final fake = FakeGridCliService()
      ..stubStart(
        _args,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine grid-app...')],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        nodeNameProvider.overrideWithValue('grid-app'),
      ],
    );
    addTearDown(container.dispose);

    final seen = <ProviderRunState>[];
    container.listen(providerRunControllerProvider, (_, next) => seen.add(next));

    await container.read(providerRunControllerProvider.notifier).startExternal(
          network: 'net',
          endpoint: 'http://x/v1',
          model: 'm',
        );

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).starting, isFalse);
    expect(seen.whereType<ProviderRunActive>(), isNotEmpty);
  });

  test('a successful join re-runs grid sync to refresh the grid list',
      () async {
    // After the engine joins it's advertised on the grid, so the controller
    // kicks off a `grid sync` to pull the refreshed list/tokens.
    final cli = _RecordingCli()
      ..stubStart(
        _args,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine grid-app...')],
      );
    // Drop the post-join sync delay so the fire-and-forget sync runs at once.
    final container = ProviderContainer(overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      nodeNameProvider.overrideWithValue('grid-app'),
      syncDelayAfterJoinProvider.overrideWithValue(Duration.zero),
    ]);
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startExternal(
          network: 'net',
          endpoint: 'http://x/v1',
          model: 'm',
        );
    // The post-join sync is fire-and-forget; let it reach the CLI.
    await Future<void>.delayed(Duration.zero);

    expect(cli.runs, contains(equals(const ['sync'])));
  });

  test('non-zero exit surfaces a failure', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        _args,
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'token has no provider scope')],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        nodeNameProvider.overrideWithValue('grid-app'),
      ],
    );
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startExternal(
          network: 'net',
          endpoint: 'http://x/v1',
          model: 'm',
        );

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunFailed>());
    expect((state as ProviderRunFailed).message, contains('scope'));
  });

  test('startLocal serves a local model via --serve (built-in engine)', () async {
    // A free port is picked and passed via --endpoint-port so the join never
    // collides with a common default (8081) another app may already hold.
    const localArgs = [
      'join', 'net',
      '--serve', 'qwen.gguf',
      '--endpoint-port', '54321',
      '--advertise-as', 'qwen',
      '--name', 'grid-app',
    ];
    final fake = FakeGridCliService()
      ..stubStart(
        localArgs,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Serving qwen.gguf…')],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        nodeNameProvider.overrideWithValue('grid-app'),
        freePortFinderProvider.overrideWithValue(() async => 54321),
      ],
    );
    addTearDown(container.dispose);

    final seen = <ProviderRunState>[];
    container.listen(providerRunControllerProvider, (_, next) => seen.add(next));

    await container.read(providerRunControllerProvider.notifier).startLocal(
          network: 'net',
          model: 'qwen.gguf',
          advertiseAs: 'qwen',
        );

    // Matched the --serve command (the fake returns its default empty run
    // otherwise, never emitting an active state).
    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect(seen.whereType<ProviderRunActive>(), isNotEmpty);
    // The served gguf is recorded so the model manager can guard against
    // deleting it while it's live.
    expect((state as ProviderRunActive).model, 'qwen.gguf');
    expect(container.read(servingModelProvider), 'qwen.gguf');
  });

  test('startLocal passes the chosen context length via --ctx-size', () async {
    // The context-length slider hands startLocal a token count; it must reach
    // the join as `--ctx-size <n>` so the engine caps the model's context.
    const localArgs = [
      'join', 'net',
      '--serve', 'qwen.gguf',
      '--endpoint-port', '54321',
      '--advertise-as', 'qwen',
      '--ctx-size', '131072',
      '--name', 'grid-app',
    ];
    final fake = FakeGridCliService()
      ..stubStart(
        localArgs,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Serving qwen.gguf…')],
      );
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        nodeNameProvider.overrideWithValue('grid-app'),
        freePortFinderProvider.overrideWithValue(() async => 54321),
      ],
    );
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startLocal(
          network: 'net',
          model: 'qwen.gguf',
          advertiseAs: 'qwen',
          ctxSize: 131072,
        );

    // Matched the --ctx-size command (the fake returns its default empty run
    // otherwise, never emitting an active state).
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
  });

  test('startLocal self-heals when the chosen port is already in use', () async {
    // First join loses the race for port 5000; the controller picks a fresh
    // port (5001) and retries, which succeeds.
    const argsPortA = [
      'join', 'net',
      '--serve', 'qwen.gguf',
      '--endpoint-port', '5000',
      '--advertise-as', 'qwen',
      '--name', 'grid-app',
    ];
    const argsPortB = [
      'join', 'net',
      '--serve', 'qwen.gguf',
      '--endpoint-port', '5001',
      '--advertise-as', 'qwen',
      '--name', 'grid-app',
    ];
    final fake = FakeGridCliService()
      ..stubStart(argsPortA, exitCode: 1, lines: const [
        CliLine(isStderr: true, text: 'Port 5000 already in use; aborting.'),
      ])
      ..stubStart(
        argsPortB,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Serving qwen.gguf…')],
      );
    // Hand out a distinct port on each pick so the retry lands on a new one.
    final ports = <int>[5000, 5001];
    var pick = 0;
    final container = ProviderContainer(
      overrides: [
        gridCliServiceProvider.overrideWithValue(fake),
        nodeNameProvider.overrideWithValue('grid-app'),
        freePortFinderProvider.overrideWithValue(() async => ports[pick++]),
      ],
    );
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startLocal(
          network: 'net',
          model: 'qwen.gguf',
          advertiseAs: 'qwen',
        );

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).starting, isFalse);
    expect(pick, 2); // picked twice: initial + one retry
  });

  test('fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startExternal(
          network: 'net',
          endpoint: 'http://x/v1',
          model: 'm',
        );
    expect(container.read(providerRunControllerProvider), isA<ProviderRunFailed>());
  });

  test('reconcile resumes a surviving engine as active for its grid', () {
    // pid = the test process itself, which is alive — stands in for a `grid join`
    // engine that outlived an app restart.
    final container = _containerWith(
      FakeGridCliService(),
      store: _StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: const ['m'], pid: io.pid),
        log: const ['Engine serving [m] via the relay'],
      ),
    );
    addTearDown(container.dispose);

    container.read(providerRunControllerProvider.notifier).reconcile('net');

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).starting, isFalse);
    expect(state.grid, 'net');
    expect(state.log, contains('Engine serving [m] via the relay'));
  });

  test('reconcile adopts a remote engine whose id differs from the node name',
      () {
    // In remote mode the CLI keys the run record by a fixed engine id (`remote`),
    // not our `--name` (here 'grid-app'). Reconcile must still find and adopt it,
    // and read its log by the record's own id — the old name-keyed lookup missed
    // `remote.json` and left the engine unadoptable (no Stop) after a restart.
    final store = _StubHomeStore(
      record: EngineRunRecord(
          engineId: 'remote', gridId: 'net', models: const ['m'], pid: io.pid),
      log: const ['Engine serving [m] via the relay'],
    );
    final container = _containerWith(FakeGridCliService(), store: store);
    addTearDown(container.dispose);

    container.read(providerRunControllerProvider.notifier).reconcile('net');

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).grid, 'net');
    expect(state.log, contains('Engine serving [m] via the relay'));
    expect(store.logEngineIdAsked, 'remote');
  });

  test('reconcile ignores a stale record whose process is gone', () {
    final container = _containerWith(
      FakeGridCliService(),
      store: _StubHomeStore(
        record: const EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: ['m'], pid: 2147483647),
      ),
    );
    addTearDown(container.dispose);

    container.read(providerRunControllerProvider.notifier).reconcile('net');

    expect(container.read(providerRunControllerProvider), isA<ProviderRunIdle>());
  });

  test('reconcile runs once per grid', () {
    final container = _containerWith(
      FakeGridCliService(),
      store: _StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: const ['m'], pid: io.pid),
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(providerRunControllerProvider.notifier);
    notifier.reconcile('net');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
    // A second call for the same grid is a no-op (no throw, state unchanged).
    notifier.reconcile('net');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
  });

  test('stop after reconcile leaves the resumed engine and goes stopped',
      () async {
    final container = _containerWith(
      FakeGridCliService(),
      store: _StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: const ['m'], pid: io.pid),
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(providerRunControllerProvider.notifier);
    notifier.reconcile('net');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());

    await notifier.stop();
    expect(container.read(providerRunControllerProvider), isA<ProviderRunStopped>());
  });

  test('stop settles to Stopped even when grid leave hangs', () async {
    // A wedged relay makes `grid leave` never return; the Stop action must
    // still land the UI on "Stopped" via its timeout, never strand it on
    // "Engine running". The timeout is shrunk so the test doesn't wait 6s.
    final container = ProviderContainer(overrides: [
      gridCliServiceProvider.overrideWithValue(_HangingLeaveCli()),
      nodeNameProvider.overrideWithValue('grid-app'),
      gridHomeStoreProvider.overrideWithValue(_StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: const ['m'], pid: io.pid),
      )),
      leaveTimeoutProvider.overrideWithValue(const Duration(milliseconds: 20)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(providerRunControllerProvider.notifier);
    notifier.reconcile('net');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());

    await notifier.stop();
    expect(container.read(providerRunControllerProvider), isA<ProviderRunStopped>());
  });

  test('starting on a new grid leaves the engine on the previous grid',
      () async {
    // Only one engine at a time: starting on gridB must `grid leave` gridA
    // first, so the detached gridA engine isn't orphaned (untracked, still
    // serving via the relay).
    const argsB = [
      'join', 'gridB',
      '--at', 'http://x/v1',
      '-m', 'm',
      '--ctx-size', '200000',
      '--name', 'grid-app',
    ];
    final cli = _RecordingCli()
      ..stubStart(
        argsB,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine grid-app...')],
      );
    final container = _containerWith(
      cli,
      store: _StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'gridA', models: const ['m'], pid: io.pid),
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(providerRunControllerProvider.notifier);
    notifier.reconcile('gridA');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());

    await notifier.startExternal(
        network: 'gridB', endpoint: 'http://x/v1', model: 'm');

    expect(cli.runs, contains(equals(const ['leave', 'gridA'])));
    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).grid, 'gridB');
  });

  test('shutdownServing leaves the in-session engine and goes idle', () async {
    final cli = _RecordingCli();
    final container = _containerWith(
      cli,
      store: _StubHomeStore(
        record: EngineRunRecord(
            engineId: 'grid-app', gridId: 'net', models: const ['m'], pid: io.pid),
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(providerRunControllerProvider.notifier);
    notifier.reconcile('net');
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());

    await notifier.shutdownServing();

    expect(cli.runs, contains(equals(const ['leave', 'net'])));
    expect(container.read(providerRunControllerProvider), isA<ProviderRunIdle>());
  });

  test('shutdownServing leaves a leftover engine found under ~/.grid', () async {
    // No engine started this session, but a run record exists on disk (e.g. a
    // prior session we never reconciled). Sign-out/close must still leave it.
    final cli = _RecordingCli();
    final container = _containerWith(
      cli,
      store: _StubHomeStore(serving: const ['ghost']),
    );
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).shutdownServing();

    expect(cli.runs, contains(equals(const ['leave', 'ghost'])));
    expect(container.read(providerRunControllerProvider), isA<ProviderRunIdle>());
  });

  test('start self-heals when a stale engine blocks the join', () async {
    // First join fails because the engine is already joined; the controller
    // `grid leave`s it and retries, which succeeds.
    final fake = FakeGridCliService()
      ..stubStart(_args, exitCode: 1, lines: const [
        CliLine(
            isStderr: true,
            text: "Engine 'grid-app' is already joined to net. "
                'Use a different --name.'),
      ])
      ..stubStart(
        _args,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine grid-app...')],
      );
    final container = _containerWith(fake);
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startExternal(
          network: 'net',
          endpoint: 'http://x/v1',
          model: 'm',
        );

    final state = container.read(providerRunControllerProvider);
    expect(state, isA<ProviderRunActive>());
    expect((state as ProviderRunActive).starting, isFalse);
  });

  test('startApiEngine joins via --api with the key in the env, not argv',
      () async {
    // `--api <kind> [-m …]`; the secret rides in the environment so it never
    // reaches the command line (and so never the Debug tab / CLI transcript).
    const apiArgs = [
      'join', 'net',
      '--api', 'openai',
      '-m', 'openai:gpt-5.5',
      '--name', 'grid-app',
    ];
    final fake = FakeGridCliService()
      ..stubStart(
        apiArgs,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine…')],
      );
    final container = _containerWith(fake);
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startApiEngine(
          network: 'net',
          kind: 'openai',
          envVar: 'OPENAI_API_KEY',
          apiKey: 'sk-secret',
          models: const ['openai:gpt-5.5'],
        );

    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
    expect(fake.lastStartArgs, apiArgs);
    expect(fake.lastStartArgs, isNot(contains('sk-secret')));
    expect(fake.lastStartEnvironment, {'OPENAI_API_KEY': 'sk-secret'});
  });

  test('startApiEngine with no models omits -m and passes no env for a stored key',
      () async {
    // No models = serve the whole whitelist (the CLI's zero-config default), and
    // an empty key means "use the key the CLI already stored" — no env override.
    const apiArgs = ['join', 'net', '--api', 'openai', '--name', 'grid-app'];
    final fake = FakeGridCliService()
      ..stubStart(
        apiArgs,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Joining engine…')],
      );
    final container = _containerWith(fake);
    addTearDown(container.dispose);

    await container.read(providerRunControllerProvider.notifier).startApiEngine(
          network: 'net',
          kind: 'openai',
          envVar: 'OPENAI_API_KEY',
          apiKey: '',
        );

    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
    expect(fake.lastStartArgs, apiArgs);
    expect(fake.lastStartEnvironment, isNull);
  });
}
