import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/http_log.dart';
import 'package:grid_app/infrastructure/logging/log_file.dart';

void main() {
  late Directory dir;
  late Directory logs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('grid_http_log_test');
    logs = Directory('${dir.path}/logs');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // A fixed clock so the dated filename is deterministic across the run.
  DailyLogFile daily() => DailyLogFile(
    logs,
    'app_https',
    clock: () => DateTime(2026, 7, 10, 9, 5, 3),
  );

  group('FileHttpLog', () {
    test('writes the request line the moment it starts, to a dated file', () {
      final file = daily();
      FileHttpLog(file).start(3, 'POST https://api/x/chat');

      final text = file.currentFile.readAsStringSync();
      expect(file.currentFile.path, endsWith('app_https-20260710.log'));
      expect(text, contains('#3 → POST https://api/x/chat'));
    });

    test('records a 2xx outcome as ok with status and duration', () {
      final file = daily();
      FileHttpLog(
        file,
      ).finish(3, statusCode: 200, duration: const Duration(seconds: 1));

      expect(
        file.currentFile.readAsStringSync(),
        contains('#3 ← ok status=200 (1s)'),
      );
    });

    test('records a non-2xx status as a failure', () {
      final file = daily();
      FileHttpLog(file).finish(4, statusCode: 500);

      expect(
        file.currentFile.readAsStringSync(),
        contains('#4 ← FAILED status=500'),
      );
    });

    test('records a transport error as a failure with its message', () {
      final file = daily();
      FileHttpLog(file).finish(5, error: 'connection refused');

      final text = file.currentFile.readAsStringSync();
      expect(text, contains('#5 ← FAILED'));
      expect(text, contains(': connection refused'));
    });
  });

  group('NoopHttpLog', () {
    test('records nothing and never throws', () {
      const log = NoopHttpLog();
      expect(() => log.start(1, 'POST x'), returnsNormally);
      expect(() => log.finish(1, statusCode: 200), returnsNormally);
    });
  });
}
