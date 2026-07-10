import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';
import 'package:grid_app/infrastructure/logging/log_file.dart';

void main() {
  late Directory dir;
  late Directory logs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('grid_app_log_test');
    logs = Directory('${dir.path}/logs');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // A fixed clock so the dated filename is deterministic across the run.
  DailyLogFile daily() =>
      DailyLogFile(logs, 'app', clock: () => DateTime(2026, 7, 10, 9, 5, 3));

  group('FileAppLog', () {
    test('writes a stamped, level-and-category tagged line', () {
      final file = daily();
      FileAppLog(file).info('app', 'Grid starting');

      final text = file.currentFile.readAsStringSync();
      expect(text, contains('INFO '));
      expect(text, contains('app'));
      expect(text, contains('Grid starting'));
    });

    test('writes to a dated file so no single log grows without bound', () {
      final file = daily();
      FileAppLog(file).info('app', 'hi');

      expect(file.currentFile.path, endsWith('app-20260710.log'));
    });

    test('creates the logs directory on demand', () {
      final file = daily();
      expect(logs.existsSync(), isFalse);
      FileAppLog(file).info('app', 'hi');
      expect(file.currentFile.existsSync(), isTrue);
    });

    test('appends the error and an indented stack trace on a failure', () {
      final file = daily();
      FileAppLog(file).failure(
        'flutter',
        'render overflow',
        error: StateError('bad'),
        stackTrace: StackTrace.fromString('#0 first\n#1 second'),
      );

      final text = file.currentFile.readAsStringSync();
      expect(text, contains('ERROR'));
      expect(text, contains('render overflow'));
      expect(text, contains('err=Bad state: bad'));
      expect(text, contains('    #0 first'));
      expect(text, contains('    #1 second'));
    });

    test('every level renders a distinct tag', () {
      final file = daily();
      FileAppLog(file)
        ..debug('cli', 'd')
        ..info('cli', 'i')
        ..warn('cli', 'w')
        ..failure('cli', 'e');

      final text = file.currentFile.readAsStringSync();
      expect(text, contains('DEBUG'));
      expect(text, contains('INFO '));
      expect(text, contains('WARN '));
      expect(text, contains('ERROR'));
    });
  });

  group('NoopAppLog', () {
    test('records nothing and never throws', () {
      const log = NoopAppLog();
      expect(() => log.failure('app', 'x', error: 'y'), returnsNormally);
    });
  });
}
