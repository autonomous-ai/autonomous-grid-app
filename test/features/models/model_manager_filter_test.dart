import 'package:grid_app/features/models/logic/model_group.dart';
import 'package:grid_app/features/models/logic/model_manager_filter.dart';
import 'package:grid_app/features/models/logic/model_shelf.dart';
import 'package:grid_app/infrastructure/api/models/model_catalog.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:flutter_test/flutter_test.dart';

ShelfModel _installed(String name, {int bytes = 1000000000}) {
  final file = LocalModel(
    name: '$name.gguf',
    path: '/tmp/models/$name.gguf',
    sizeBytes: bytes,
  );
  return ShelfModel(
    name: name,
    group: ModelGroup(
      displayName: '$name.gguf',
      files: [file],
      primary: file,
      isSplit: false,
    ),
  );
}

CatalogModelPick _pick({String? repo, String? file}) => CatalogModelPick(
  repoId: repo,
  version: 'Q4_K_M',
  sizeBytes: 4000000000,
  file: file,
  maxCtx: 131072,
  estTokPerSec: 20,
  pullSpec: '$repo:$file',
  urls: const [],
);

void main() {
  group('looksLikePullSpec', () {
    test('accepts a single owner/repo:file.gguf', () {
      expect(
        looksLikePullSpec('unsloth/Qwen3.6-35B-MTP-GGUF:Qwen3.6-UD-IQ3_S.gguf'),
        isTrue,
      );
    });

    test('accepts every line of a split paste', () {
      expect(
        looksLikePullSpec(
          'owner/repo:model-00001-of-00002.gguf\n'
          'owner/repo:model-00002-of-00002.gguf',
        ),
        isTrue,
      );
    });

    // A stray word among specs is a typo, not a download — treating the whole
    // paste as a spec would start a pull that fails on the bad line.
    test('rejects a paste where one line is not a spec', () {
      expect(looksLikePullSpec('owner/repo:a.gguf\nqwen'), isFalse);
    });

    test('rejects ordinary search words', () {
      expect(looksLikePullSpec('qwen'), isFalse);
      expect(looksLikePullSpec('llama 3'), isFalse);
      expect(looksLikePullSpec(''), isFalse);
      expect(looksLikePullSpec('   '), isFalse);
    });

    // Without the .gguf tail this is a plain repo name, and the CLI can't pull
    // it — offering Download would hand the user a guaranteed failure.
    test('rejects a repo with no file', () {
      expect(looksLikePullSpec('unsloth/Qwen3.6-GGUF'), isFalse);
    });
  });

  group('filterInstalled', () {
    final shelf = [
      _installed('Qwen3.6-35B-A3B-UD-IQ3_S'),
      _installed('Llama-3.3-8B-Instruct-Q5_K_M'),
    ];

    test('empty query keeps everything', () {
      expect(filterInstalled(shelf, ''), hasLength(2));
      expect(filterInstalled(shelf, '   '), hasLength(2));
    });

    test('matches case-insensitively on the name', () {
      final hits = filterInstalled(shelf, 'llama');
      expect(hits, hasLength(1));
      expect(hits.single.name, startsWith('Llama'));
    });

    test('no match returns empty rather than everything', () {
      expect(filterInstalled(shelf, 'mistral'), isEmpty);
    });
  });

  group('filterPicks', () {
    final picks = [
      _pick(repo: 'Qwen/Qwen3.6-14B-GGUF', file: 'qwen3.6-14b-q4.gguf'),
      _pick(repo: 'google/gemma-3-12b-GGUF', file: 'gemma-3-12b-q4.gguf'),
    ];

    // The row shows a shortened name, but people search by the full owner/repo
    // they read elsewhere.
    test('matches on the repo id, not just the shown name', () {
      expect(filterPicks(picks, 'google'), hasLength(1));
    });

    test('matches on the filename', () {
      expect(filterPicks(picks, 'gemma-3-12b-q4'), hasLength(1));
    });

    test('a null repo/file does not throw', () {
      final sparse = [_pick()];
      expect(filterPicks(sparse, 'anything'), isEmpty);
    });
  });

  group('totalInstalledBytes', () {
    test('sums every group on the shelf', () {
      final shelf = [
        _installed('a', bytes: 1500000000),
        _installed('b', bytes: 2500000000),
      ];
      expect(totalInstalledBytes(shelf), 4000000000);
    });

    // A suggestion that isn't downloaded has no group, and must not be counted
    // as disk that could be freed.
    test('ignores rows that are not on disk', () {
      final shelf = [
        _installed('a', bytes: 1000000000),
        const ShelfModel(name: 'not-downloaded'),
      ];
      expect(totalInstalledBytes(shelf), 1000000000);
    });
  });

  group('formatGb', () {
    test('drops the decimal once it is noise', () {
      expect(formatGb(15350000000), '15 GB');
    });

    test('keeps one decimal below 10 GB', () {
      expect(formatGb(5730000000), '5.7 GB');
    });

    // A 400 MB model printed as "0.4 GB" reads as a rounding error.
    test('falls back to MB under 1 GB', () {
      expect(formatGb(400000000), '400 MB');
    });
  });
}
