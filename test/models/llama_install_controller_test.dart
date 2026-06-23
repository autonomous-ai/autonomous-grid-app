import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/llama_install_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

void main() {
  test('streams log then marks done on exit 0', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['llama.cpp', 'install'],
        exitCode: 0,
        exitDelay: const Duration(milliseconds: 10),
        lines: const [
          CliLine(isStderr: false, text: '==> Installing llama.cpp'),
          CliLine(isStderr: false, text: 'Linked -> ~/.grid/bin/llama-server'),
        ],
      );
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    final seen = <LlamaInstallState>[];
    container.listen(llamaInstallControllerProvider, (_, next) => seen.add(next));

    await container.read(llamaInstallControllerProvider.notifier).install();

    expect(container.read(llamaInstallControllerProvider), isA<LlamaInstallDone>());
    expect(seen.whereType<LlamaInstalling>(), isNotEmpty);
  });

  test('fails with the last log line on non-zero exit', () async {
    final fake = FakeGridCliService()
      ..stubStart(
        ['llama.cpp', 'install'],
        exitCode: 1,
        lines: const [CliLine(isStderr: true, text: 'brew: command not found')],
      );
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await container.read(llamaInstallControllerProvider.notifier).install();

    final state = container.read(llamaInstallControllerProvider);
    expect(state, isA<LlamaInstallFailed>());
    expect((state as LlamaInstallFailed).message, contains('brew'));
  });

  test('fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container.read(llamaInstallControllerProvider.notifier).install();
    expect(container.read(llamaInstallControllerProvider), isA<LlamaInstallFailed>());
  });
}
