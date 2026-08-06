import 'package:grid_app/features/models/logic/model_manager_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isCatalogModelInstalled', () {
    const onDisk = [
      'qwen2.5-3b-instruct-q4_k_m.gguf',
      'Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf',
    ];

    test('matches the exact file a pick would download', () {
      expect(
        isCatalogModelInstalled(
          repoId: 'unrelated/repo',
          file: 'qwen2.5-3b-instruct-q4_k_m.gguf',
          localFileNames: onDisk,
        ),
        isTrue,
      );
    });

    // The list endpoint gives a repo id and nothing else, so the repo's tail has
    // to carry the match on its own — through the punctuation and the -GGUF
    // suffix the filename doesn't have.
    test('matches a repo id against a filename from that repo', () {
      expect(
        isCatalogModelInstalled(
          repoId: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
          localFileNames: onDisk,
        ),
        isTrue,
      );
    });

    // Having Q5 of a model still answers "do I have this one?" with yes —
    // listing it under "Not installed" invites a second copy of the same model.
    test('counts a different quant of the same model as installed', () {
      expect(
        isCatalogModelInstalled(
          repoId: 'bartowski/Meta-Llama-3.1-8B-Instruct-GGUF',
          file: 'meta-llama-3.1-8b-instruct-q8_0.gguf',
          localFileNames: onDisk,
        ),
        isTrue,
      );
    });

    test('says no for a model that is not on disk', () {
      expect(
        isCatalogModelInstalled(
          repoId: 'mistralai/Mistral-7B-Instruct-v0.3-GGUF',
          localFileNames: onDisk,
        ),
        isFalse,
      );
    });

    test('is false against an empty shelf', () {
      expect(
        isCatalogModelInstalled(
          repoId: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
          localFileNames: const [],
        ),
        isFalse,
      );
    });

    // A two- or three-character stem appears inside half the shelf by accident;
    // refusing it is what keeps the filter from calling everything installed.
    test('refuses to match on a stem too short to mean anything', () {
      expect(
        isCatalogModelInstalled(repoId: 'x/q4', localFileNames: onDisk),
        isFalse,
      );
    });
  });
}
