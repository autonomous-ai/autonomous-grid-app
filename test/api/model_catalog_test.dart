import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/model_catalog.dart';

// A trimmed `POST /v1/grid/catalog` suggest response (the doc's §4A shape).
const _suggestBody = '''
{
  "mode": "suggest",
  "pick": {
    "repo_id": "Qwen/Qwen2.5-3B-Instruct-GGUF",
    "version": "Q5_K_M",
    "size": 2439805440,
    "file": "qwen2.5-3b-instruct-q5_k_m.gguf",
    "max_ctx": 32768,
    "est_tok_s": 8.1,
    "pull_spec": "Qwen/Qwen2.5-3B-Instruct-GGUF:qwen2.5-3b-instruct-q5_k_m.gguf",
    "urls": ["https://huggingface.co/Qwen/x/resolve/main/q5_k_m.gguf"]
  },
  "alternatives": [
    {
      "repo_id": "meta-llama/Llama-3.2-3B-Instruct-GGUF",
      "version": "Q6_K",
      "size": 2019000000,
      "file": "llama-3.2-3b-instruct-q6_k.gguf",
      "max_ctx": 131072,
      "est_tok_s": 12.7,
      "pull_spec": "meta-llama/Llama-3.2-3B-Instruct-GGUF:llama-3.2-3b-instruct-q6_k.gguf",
      "urls": ["https://huggingface.co/meta-llama/x/resolve/main/q6_k.gguf"]
    }
  ],
  "device_echo": {"device_class": "cpu"}
}
''';

// The "nothing fits this machine" sentinel from §4A.
const _noMatchBody = '''
{ "mode": "suggest",
  "pick": { "repo_id": null, "version": null, "size": 0, "file": null,
            "max_ctx": 0, "est_tok_s": 0.0, "pull_spec": null, "urls": [] },
  "alternatives": [], "device_echo": {} }
''';

void main() {
  group('CatalogModelPick.fromJson', () {
    test('parses a suggest pick with all fields', () {
      final pick = CatalogModelPick.fromJson(const {
        'repo_id': 'Qwen/Qwen2.5-3B-Instruct-GGUF',
        'version': 'Q5_K_M',
        'size': 2439805440,
        'file': 'qwen2.5-3b-instruct-q5_k_m.gguf',
        'max_ctx': 32768,
        'est_tok_s': 8.1,
        'pull_spec':
            'Qwen/Qwen2.5-3B-Instruct-GGUF:qwen2.5-3b-instruct-q5_k_m.gguf',
        'urls': ['https://huggingface.co/a', 'https://huggingface.co/b'],
      });
      expect(pick.hasModel, isTrue);
      expect(pick.version, 'Q5_K_M');
      expect(pick.sizeBytes, 2439805440);
      expect(pick.maxCtx, 32768);
      expect(pick.estTokPerSec, closeTo(8.1, 0.001));
      expect(pick.pullSpec, contains(':'));
      expect(pick.urls, hasLength(2));
    });

    test('accepts the list shape (size_bytes / max_context) too', () {
      final pick = CatalogModelPick.fromJson(const {
        'repo_id': 'x/y',
        'size_bytes': 4680000000,
        'max_context': 32768,
        'pull_spec': 'x/y:z.gguf',
      });
      expect(pick.sizeBytes, 4680000000);
      expect(pick.maxCtx, 32768);
      expect(pick.estTokPerSec, 0); // list mode never sets speed
    });

    test('the no-match sentinel has no model', () {
      final pick = CatalogModelPick.fromJson(const {
        'repo_id': null,
        'size': 0,
        'pull_spec': null,
        'urls': <dynamic>[],
      });
      expect(pick.hasModel, isFalse);
    });

    test('drops non-string / empty urls', () {
      final pick = CatalogModelPick.fromJson(const {
        'repo_id': 'x/y',
        'pull_spec': 'x/y:z',
        'urls': ['https://ok', '', 42, null],
      });
      expect(pick.urls, ['https://ok']);
    });
  });

  group('parseSuggestResponse', () {
    test('ranks pick first, then real alternatives', () {
      final suggestion = parseSuggestResponse(_suggestBody);
      expect(suggestion, isNotNull);
      final ranked = suggestion!.ranked;
      expect(ranked.map((m) => m.repoId), [
        'Qwen/Qwen2.5-3B-Instruct-GGUF',
        'meta-llama/Llama-3.2-3B-Instruct-GGUF',
      ]);
    });

    test('the no-match sentinel yields an empty ranking', () {
      final suggestion = parseSuggestResponse(_noMatchBody);
      expect(suggestion, isNotNull);
      expect(suggestion!.pick.hasModel, isFalse);
      expect(suggestion.ranked, isEmpty);
    });

    test('a list-mode body is not a suggest response', () {
      expect(parseSuggestResponse('{"mode":"list","models":[]}'), isNull);
    });

    test('malformed JSON is null, never a throw', () {
      expect(parseSuggestResponse('not json {['), isNull);
    });
  });
}
