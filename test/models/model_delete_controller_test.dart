import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/model_delete_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Records `run` calls so tests can assert the `grid rm` command.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

void main() {
  test('delete runs `grid rm <name>` and returns to idle', () async {
    final cli = _RecordingCli();
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(cli)],
    );
    addTearDown(container.dispose);

    final ok = await container
        .read(modelDeleteControllerProvider.notifier)
        .delete(['qwen.gguf'], label: 'qwen.gguf');

    expect(ok, isTrue);
    expect(cli.runs, contains(equals(const ['rm', 'qwen.gguf'])));
    expect(container.read(modelDeleteControllerProvider), isA<ModelDeleteIdle>());
  });

  test('delete removes every file of a split model', () async {
    final cli = _RecordingCli();
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(cli)],
    );
    addTearDown(container.dispose);

    final files = [
      'MiniMax-M3-00001-of-00002.gguf',
      'MiniMax-M3-00002-of-00002.gguf',
    ];
    final ok = await container
        .read(modelDeleteControllerProvider.notifier)
        .delete(files, label: 'MiniMax-M3');

    expect(ok, isTrue);
    expect(cli.runs, contains(equals(['rm', files[0]])));
    expect(cli.runs, contains(equals(['rm', files[1]])));
    expect(container.read(modelDeleteControllerProvider), isA<ModelDeleteIdle>());
  });

  test('delete surfaces a failure when the CLI returns non-zero', () async {
    final cli = _RecordingCli()
      ..stubResult(['rm', 'qwen.gguf'],
          const CliResult(exitCode: 1, stdout: '', stderr: 'no such model'));
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(cli)],
    );
    addTearDown(container.dispose);

    final ok = await container
        .read(modelDeleteControllerProvider.notifier)
        .delete(['qwen.gguf'], label: 'qwen.gguf');

    expect(ok, isFalse);
    expect(
        container.read(modelDeleteControllerProvider), isA<ModelDeleteFailed>());
  });

  test('delete fails fast when the CLI is unavailable', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    final ok = await container
        .read(modelDeleteControllerProvider.notifier)
        .delete(['x.gguf'], label: 'x.gguf');

    expect(ok, isFalse);
    expect(
        container.read(modelDeleteControllerProvider), isA<ModelDeleteFailed>());
  });

  group('isModelInUse', () {
    test('exact gguf match — the in-session built-in serve', () {
      expect(
          isModelInUse('Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
              'Qwen3.6-35B-A3B-UD-IQ3_S.gguf'),
          isTrue);
    });

    test('advertised-name prefix match — an engine adopted on restart', () {
      expect(isModelInUse('Qwen3.6-35B-A3B-UD-IQ3_S.gguf', 'Qwen3.6-35B-A3B'),
          isTrue);
    });

    test('a different model is not in use', () {
      expect(isModelInUse('llama3.gguf', 'Qwen3.6-35B-A3B'), isFalse);
    });

    test('nothing serving means nothing in use', () {
      expect(isModelInUse('llama3.gguf', null), isFalse);
      expect(isModelInUse('llama3.gguf', ''), isFalse);
    });
  });
}
