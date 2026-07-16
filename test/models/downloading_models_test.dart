import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_downloading_models_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  File touch(String name, {int bytes = 0}) {
    final file = File('${tmp.path}/$name')
      ..writeAsBytesSync(List.filled(bytes, 0));
    return file;
  }

  test('a `.gguf.part` reads as a download in progress, named as the model it '
      'will become', () {
    touch('Qwen3.6-35B-A3B-UD-IQ3_S.gguf.part', bytes: 2048);

    final downloading = scanDownloadingModels(tmp);

    expect(downloading, hasLength(1));
    expect(downloading.single.name, 'Qwen3.6-35B-A3B-UD-IQ3_S.gguf');
    expect(downloading.single.bytesSoFar, 2048);
  });

  test(
    'a finished `.gguf` is not a download — it belongs to the model list, not '
    'here',
    () {
      touch('done.gguf', bytes: 4096);

      expect(scanDownloadingModels(tmp), isEmpty);
    },
  );

  test(
    'mid-download, the same model can be both finished and in-flight without '
    'the part-file masking the real one',
    () {
      // A split model: one shard landed, the next is still coming down.
      touch('model-00001-of-00002.gguf', bytes: 10);
      touch('model-00002-of-00002.gguf.part', bytes: 5);

      final downloading = scanDownloadingModels(tmp);

      expect(downloading.map((d) => d.name), ['model-00002-of-00002.gguf']);
    },
  );

  test('a models directory that was never created reads as no downloads, not a '
      'crash', () {
    final gone = Directory('${tmp.path}/nope');
    expect(scanDownloadingModels(gone), isEmpty);
  });
}
