import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/pull_spec.dart';

const _repo = 'unsloth/Qwen3-Coder-Next-GGUF';
const _quantDir = 'Q4_1/Qwen3-Coder-Next-Q4_1';

String _url(String path) => 'https://huggingface.co/$_repo/resolve/main/$path';

void main() {
  group('versionPullSpecs', () {
    test(
      'pulls every part of a split model, not just the one pull_spec names',
      () {
        // The catalog's pull_spec is always the first shard, so honouring it alone
        // left two thirds of the model missing and nothing servable on disk.
        final specs = versionPullSpecs(
          urls: [
            _url('$_quantDir-00001-of-00003.gguf'),
            _url('$_quantDir-00002-of-00003.gguf'),
            _url('$_quantDir-00003-of-00003.gguf'),
          ],
          pullSpec: '$_repo:$_quantDir-00001-of-00003.gguf',
        );

        expect(specs, [
          '$_repo:$_quantDir-00001-of-00003.gguf',
          '$_repo:$_quantDir-00002-of-00003.gguf',
          '$_repo:$_quantDir-00003-of-00003.gguf',
        ]);
      },
    );

    test('a one-file version stays one spec', () {
      final specs = versionPullSpecs(
        urls: [_url('Qwen3-Coder-Next-UD-IQ1_M.gguf')],
        pullSpec: '$_repo:Qwen3-Coder-Next-UD-IQ1_M.gguf',
      );

      expect(specs, ['$_repo:Qwen3-Coder-Next-UD-IQ1_M.gguf']);
    });

    test('falls back to pull_spec when the catalog sends no urls', () {
      expect(versionPullSpecs(urls: const [], pullSpec: '$_repo:model.gguf'), [
        '$_repo:model.gguf',
      ]);
    });

    test('a url we cannot read falls back rather than pulling a partial set', () {
      // Downloading the two parts we understood would leave a model with a hole
      // in it that reads as complete — worse than pulling only the first.
      final specs = versionPullSpecs(
        urls: [
          _url('$_quantDir-00001-of-00003.gguf'),
          'https://cdn.example.com/mirror/part-2.gguf',
        ],
        pullSpec: '$_repo:$_quantDir-00001-of-00003.gguf',
      );

      expect(specs, ['$_repo:$_quantDir-00001-of-00003.gguf']);
    });

    test('nothing to download is empty, so callers can disable the button', () {
      expect(versionPullSpecs(urls: const [], pullSpec: null), isEmpty);
      expect(versionPullSpecs(urls: const [], pullSpec: '  '), isEmpty);
    });
  });

  group('pullSpecFileName', () {
    test('drops the quant folder, because the CLI stores downloads flat', () {
      // `~/.grid/models/<basename>` is where the file actually lands. Comparing
      // against the folder-qualified path is why a finished download reported
      // "the model couldn't be found afterwards".
      expect(
        pullSpecFileName('$_repo:UD-IQ1_M/model-00001-of-00003.gguf'),
        'model-00001-of-00003.gguf',
      );
    });

    test('leaves a spec that already names a bare file alone', () {
      expect(pullSpecFileName('$_repo:model.gguf'), 'model.gguf');
    });

    test('a spec with no file half has no filename', () {
      expect(pullSpecFileName(_repo), isNull);
      expect(pullSpecFileName('$_repo:'), isNull);
      expect(pullSpecFileName('$_repo:folder/'), isNull);
    });
  });
}
