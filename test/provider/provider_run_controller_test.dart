import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

const _args = [
  'provider', 'start',
  '--network', 'net',
  '--at', 'http://x/v1',
  '--model', 'm',
];

void main() {
  test('startExternal streams log then stops cleanly on exit 0', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        _args,
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 15),
        lines: const [CliLine(isStderr: false, text: 'Registering node_id=...')],
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

    expect(container.read(providerRunControllerProvider), isA<ProviderRunStopped>());
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

  test('startLocal serves a local model with no --at endpoint', () async {
    const localArgs = [
      'provider', 'start',
      '--network', 'net',
      '--model', 'qwen.gguf',
      '--advertise-as', 'qwen',
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

    // Matched the no-`--at` command (the fake returns its default empty run
    // otherwise, never emitting an active state).
    expect(container.read(providerRunControllerProvider), isA<ProviderRunStopped>());
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
}
