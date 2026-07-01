import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

ProviderContainer _container(GridCliService? cli) {
  final container = ProviderContainer(
    overrides: [gridCliServiceProvider.overrideWithValue(cli)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('reads the model max from `grid ctx --json <model>`', () async {
    final fake = FakeGridCliService()
      ..stubResult(
        const ['ctx', '--json', 'qwen.gguf'],
        const CliResult(
          exitCode: 0,
          stdout: '{"file": "qwen.gguf", "context_length": 262144}',
          stderr: '',
        ),
      );
    final container = _container(fake);

    expect(await container.read(modelMaxContextProvider('qwen.gguf').future),
        262144);
  });

  test('returns null when the ctx command fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(const ['ctx', '--json', 'qwen.gguf'],
          const CliResult(exitCode: 1, stdout: '', stderr: 'no such model'));
    final container = _container(fake);

    expect(
        await container.read(modelMaxContextProvider('qwen.gguf').future), isNull);
  });

  test('returns null when the CLI is unavailable', () async {
    final container = _container(null);
    expect(await container.read(modelMaxContextProvider('qwen.gguf').future),
        isNull);
  });
}
