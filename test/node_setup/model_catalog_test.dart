import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/node_setup/logic/model_catalog.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

// Mirrors `grid catalog`: an optional local-models block, then the "Grid can
// pull:" block (already filtered to this host's target by the CLI), then a
// trailing hint. The parser must read only the contiguous entry block.
const _output = '''
Local models:
  qwen-old.gguf                                                7.42 GB

Grid can pull:
  qwen36-35b-a3b-mtp               unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ3_S.gguf (Apple Silicon, min 32 GB, language)
  some-embedder                    org/Embed-GGUF/embed.gguf (min 4 GB, embedding)

Also: `grid pull <hf-repo>:<file>` for any GGUF on Hugging Face.
''';

void main() {
  test('parses the recommended catalog block', () {
    final entries = ModelCatalog.parse(_output);
    expect(entries, hasLength(2));
    expect(entries.first.label, 'qwen36-35b-a3b-mtp');
    expect(entries.first.repoFile,
        'unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ3_S.gguf');
    expect(entries.first.isLanguage, isTrue);
    expect(entries[1].kind, 'embedding');
  });

  test('returns empty when there is no catalog section', () {
    expect(ModelCatalog.parse('(no local models)\n'), isEmpty);
  });

  test('defaultLanguageModel prefers a language entry over embeddings', () async {
    final fake = FakeGridCliService()
      ..stubResult(['catalog'],
          const CliResult(exitCode: 0, stdout: _output, stderr: ''));

    final model = await ModelCatalog(fake).defaultLanguageModel();
    expect(model!.label, 'qwen36-35b-a3b-mtp');
  });

  test('defaultLanguageModel is null when the CLI fails', () async {
    final fake = FakeGridCliService()
      ..stubResult(['catalog'],
          const CliResult(exitCode: 1, stdout: '', stderr: 'boom'));

    expect(await ModelCatalog(fake).defaultLanguageModel(), isNull);
  });
}
