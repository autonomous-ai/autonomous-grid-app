import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/advertise_name.dart';
import 'package:grid_app/features/models/logic/model_group.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

LocalModel _model(String name, {int sizeBytes = 1}) =>
    LocalModel(name: name, path: '/models/$name', sizeBytes: sizeBytes);

void main() {
  group('split-shard detection', () {
    test('recognises a shard and reads its index/count', () {
      const shard = 'MiniMax-M3-UD-IQ3_XXS-00002-of-00005.gguf';
      expect(isSplitShard(shard), isTrue);
      expect(splitShardIndex(shard), 2);
      expect(splitShardCount(shard), 5);
      expect(stripSplitSuffix(shard), 'MiniMax-M3-UD-IQ3_XXS');
    });

    test('a standalone file is not a shard and is left untouched', () {
      const file = 'Qwen3.6-35B-A3B-UD-IQ3_S.gguf';
      expect(isSplitShard(file), isFalse);
      expect(splitShardIndex(file), isNull);
      expect(splitShardCount(file), isNull);
      expect(stripSplitSuffix(file), file);
    });
  });

  group('groupLocalModels', () {
    test('merges a split set into one ordered, servable group', () {
      // Deliberately out of order to prove sorting by shard index.
      final groups = groupLocalModels([
        _model('MiniMax-00003-of-00003.gguf', sizeBytes: 3),
        _model('MiniMax-00001-of-00003.gguf', sizeBytes: 1),
        _model('MiniMax-00002-of-00003.gguf', sizeBytes: 2),
      ]);

      expect(groups, hasLength(1));
      final split = groups.single;
      expect(split.isSplit, isTrue);
      expect(split.displayName, 'MiniMax');
      expect(split.partCount, 3);
      expect(split.expectedParts, 3);
      expect(split.isComplete, isTrue);
      expect(split.sizeBytes, 6);
      // Primary is the first shard so the engine loads the rest by convention.
      expect(split.primary.name, 'MiniMax-00001-of-00003.gguf');
      expect(split.fileNames, [
        'MiniMax-00001-of-00003.gguf',
        'MiniMax-00002-of-00003.gguf',
        'MiniMax-00003-of-00003.gguf',
      ]);
    });

    test('an incomplete split set is flagged, not silently merged away', () {
      final groups = groupLocalModels([
        _model('Big-00001-of-00005.gguf'),
        _model('Big-00002-of-00005.gguf'),
      ]);

      final split = groups.single;
      expect(split.partCount, 2);
      expect(split.expectedParts, 5);
      expect(split.isComplete, isFalse);
    });

    test('standalone files each become their own group, order preserved', () {
      final groups = groupLocalModels([
        _model('qwen.gguf'),
        _model('llama.gguf'),
      ]);

      expect(groups.map((g) => g.displayName), ['qwen.gguf', 'llama.gguf']);
      expect(groups.every((g) => !g.isSplit), isTrue);
      expect(groups.first.primary.name, 'qwen.gguf');
    });

    test('split and standalone models coexist', () {
      final groups = groupLocalModels([
        _model('solo.gguf'),
        _model('Split-00001-of-00002.gguf'),
        _model('Split-00002-of-00002.gguf'),
      ]);

      expect(groups, hasLength(2));
      expect(groups.where((g) => g.isSplit), hasLength(1));
      expect(groups.where((g) => !g.isSplit), hasLength(1));
    });
  });

  test('advertise name drops the shard suffix as well as the quant tag', () {
    expect(
      deriveAdvertiseName('MiniMax-M3-UD-IQ3_XXS-00001-of-00005.gguf'),
      'MiniMax-M3',
    );
  });
}
