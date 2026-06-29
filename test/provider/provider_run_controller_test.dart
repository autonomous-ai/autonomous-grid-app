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
  '--name', 'grid-app',
];

/// Stubs the run-state reads so [ProviderRunController.reconcile] can be driven
/// without touching `~/.grid`.
class _StubHomeStore extends GridHomeStore {
  _StubHomeStore({this.record, this.log = const []});

  final EngineRunRecord? record;
  final List<String> log;

  @override
  EngineRunRecord? readEngineRun(String gridId, String engineName) => record;

  @override
  List<String> readEngineRunLog(String gridId, String engineName,
          {int maxLines = 400}) =>
      log;
}

ProviderContainer _containerWith(GridCliService? cli, {GridHomeStore? store}) {
  final container = ProviderContainer(overrides: [
    gridCliServiceProvider.overrideWithValue(cli),
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
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
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

  test('non-zero exit surfaces a failure', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        _args,
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'token has no provider scope')],
      );
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
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
    const localArgs = [
      'join', 'net',
      '--serve', 'qwen.gguf',
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
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
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
    expect(container.read(providerRunControllerProvider), isA<ProviderRunActive>());
    expect(seen.whereType<ProviderRunActive>(), isNotEmpty);
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
}
