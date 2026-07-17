import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Real `grid catalog` shape: a "Local models" block, the pull-able catalog
/// (each tagged with its device + min memory), then a trailing hint.
const _catalogStdout = '''
Local models:
  Qwen3.6-35B-A3B-UD-IQ3_S.gguf                                15.35 GB

Grid can pull:
  qwen36-35b-a3b-mtp   unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ3_S.gguf (Apple Silicon, min 32 GB, language)
  qwen36-27b-mtp       unsloth/Qwen3.6-27B-MTP-GGUF/Qwen3.6-27B-UD-Q5_K_XL.gguf (NVIDIA, min 24 GB, language)

Also: `grid pull <hf-repo>:<file>` for any GGUF on Hugging Face.
''';

ProviderContainer _container(GridCliService? cli) {
  final container = ProviderContainer(
    overrides: [gridCliServiceProvider.overrideWithValue(cli)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('parses the "Grid can pull" block into device-tagged entries', () async {
    final fake = FakeGridCliService()
      ..stubResult(const [
        'catalog',
      ], const CliResult(exitCode: 0, stdout: _catalogStdout, stderr: ''));
    final container = _container(fake);

    final entries = await container.read(catalogModelsProvider.future);

    // Only the two pull-able entries — the "Local models" and "Also:" lines are
    // ignored.
    expect(entries, hasLength(2));
    expect(entries.first.target, 'Apple Silicon');
    expect(entries.first.minVramGb, 32);
    expect(
      entries.first.pullSpec,
      'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
    );
    expect(entries[1].target, 'NVIDIA');
  });

  test('returns empty when the catalog command fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(const [
        'catalog',
      ], const CliResult(exitCode: 1, stdout: '', stderr: 'boom'));
    final container = _container(fake);

    expect(await container.read(catalogModelsProvider.future), isEmpty);
  });

  test('returns empty when the CLI is unavailable', () async {
    final container = _container(null);
    expect(await container.read(catalogModelsProvider.future), isEmpty);
  });
}
