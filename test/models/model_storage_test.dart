import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/model_group.dart';
import 'package:grid_app/features/models/logic/model_storage.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

LocalModel _model(String name, int bytes) =>
    LocalModel(name: name, path: '/tmp/$name', sizeBytes: bytes);

DownloadingModel _partial(String name, int bytes) =>
    DownloadingModel(name: name, path: '/tmp/$name.part', bytesSoFar: bytes);

List<StoredItem> _items({
  List<LocalModel> models = const [],
  List<DownloadingModel> partials = const [],
}) => storedItems(groups: groupLocalModels(models), partials: partials);

void main() {
  group('modelSizeLabel', () {
    test('a leftover under a gigabyte reads in MB, not "0.3 GB"', () {
      expect(modelSizeLabel(300000000), '300 MB');
    });

    test('a tenth of a gigabyte still matters at single digits', () {
      expect(modelSizeLabel(4887412736), '4.9 GB');
    });

    test('above ten gigabytes the decimal is noise', () {
      expect(modelSizeLabel(15346432288), '15 GB');
    });
  });

  group('storedItems', () {
    test('a finished model is one item, ready, with its size', () {
      final items = _items(models: [_model('qwen.gguf', 15346432288)]);

      expect(items, hasLength(1));
      expect(items.single.label, 'qwen.gguf');
      expect(items.single.kind, StoredItemKind.ready);
      expect(items.single.files, ['qwen.gguf']);
      expect(items.single.sizeBytes, 15346432288);
    });

    test('the biggest comes first — the list answers "what do I delete?"', () {
      final items = _items(
        models: [
          _model('small.gguf', 1000000000),
          _model('big.gguf', 9e9.toInt()),
        ],
      );

      expect(
        [for (final item in items) item.label],
        ['big.gguf', 'small.gguf'],
      );
    });

    test('a stalled shard joins the model it belongs to, size and all', () {
      // Exactly what a stopped split download leaves behind: one finished part
      // and one still carrying `.part`. Two rows would let the user delete the
      // 6 MB one and leave 13 GB on the disk they were trying to clear.
      final items = _items(
        models: [_model('Coder-Q4_1-00001-of-00003.gguf', 5936320)],
        partials: [_partial('Coder-Q4_1-00002-of-00003.gguf', 13542359040)],
      );

      expect(items, hasLength(1));
      final item = items.single;
      expect(item.label, 'Coder-Q4_1');
      expect(item.kind, StoredItemKind.unfinished);
      expect(item.sizeBytes, 5936320 + 13542359040);
      expect(item.files, [
        'Coder-Q4_1-00001-of-00003.gguf',
        'Coder-Q4_1-00002-of-00003.gguf.part',
      ]);
      expect(item.detail, contains('1 of 3 parts here'));
    });

    test('a download with nothing finished still shows up as its own item', () {
      final items = _items(partials: [_partial('llama.gguf', 4887412736)]);

      expect(items.single.label, 'llama.gguf');
      expect(items.single.kind, StoredItemKind.unfinished);
      expect(items.single.files, ['llama.gguf.part']);
      expect(items.single.detail, 'Download stopped partway');
    });

    test('a split set missing a shard is unfinished, not ready to serve', () {
      final items = _items(
        models: [_model('m-00001-of-00002.gguf', 1000000000)],
      );

      expect(items.single.kind, StoredItemKind.unfinished);
      expect(items.single.detail, contains('1 of 2 parts here'));
    });

    test('a whole split set is ready and says how many parts it has', () {
      final items = _items(
        models: [
          _model('m-00001-of-00002.gguf', 1000000000),
          _model('m-00002-of-00002.gguf', 1000000000),
        ],
      );

      expect(items.single.kind, StoredItemKind.ready);
      expect(items.single.detail, '2 parts');
      expect(items.single.sizeBytes, 2000000000);
    });

    test('nothing on disk is an empty list, never a throw', () {
      expect(_items(), isEmpty);
    });
  });

  group('storageSummary', () {
    test('counts what can be used apart from what only takes up space', () {
      final items = _items(
        models: [_model('qwen.gguf', 15000000000)],
        partials: [_partial('llama.gguf', 5000000000)],
      );

      expect(
        items.map((i) => i.sizeBytes).reduce((a, b) => a + b),
        20000000000,
      );
      expect(
        storageSummary(items),
        '20 GB used · 1 model · 1 unfinished download',
      );
    });

    test('plurals hold up past one of each', () {
      final items = _items(
        models: [_model('a.gguf', 1000000000), _model('b.gguf', 1000000000)],
        partials: [
          _partial('c.gguf', 1000000000),
          _partial('d.gguf', 1000000000),
        ],
      );

      expect(storageCounts(items), '2 models · 2 unfinished downloads');
    });

    test('an empty disk says so rather than "0 MB used"', () {
      expect(storageSummary(const []), 'Nothing downloaded yet');
    });
  });

  group('isStoredItemInUse', () {
    test('the shard being served protects the whole split model', () {
      final item = _items(
        models: [
          _model('Qwen3.6-35B-00001-of-00002.gguf', 1),
          _model('Qwen3.6-35B-00002-of-00002.gguf', 1),
        ],
      ).single;

      expect(
        isStoredItemInUse(item, 'Qwen3.6-35B-00001-of-00002.gguf'),
        isTrue,
      );
    });

    test('an engine adopted on restart serves an advertised name', () {
      final item = _items(models: [_model('Qwen3.6-35B-A3B-UD-IQ3_S.gguf', 1)]);

      expect(isStoredItemInUse(item.single, 'Qwen3.6-35B-A3B'), isTrue);
    });

    test('another model on the same grid does not lock this one', () {
      final item = _items(models: [_model('llama3.gguf', 1)]).single;

      expect(isStoredItemInUse(item, 'Qwen3.6-35B-A3B'), isFalse);
    });
  });

  group('isModelInUse', () {
    test('exact gguf match — the in-session built-in serve', () {
      expect(
        isModelInUse(
          'Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
          'Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
        ),
        isTrue,
      );
    });

    test('advertised-name prefix match — an engine adopted on restart', () {
      expect(
        isModelInUse('Qwen3.6-35B-A3B-UD-IQ3_S.gguf', 'Qwen3.6-35B-A3B'),
        isTrue,
      );
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
