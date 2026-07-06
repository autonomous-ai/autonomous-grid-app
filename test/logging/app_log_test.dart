import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('grid_app_log_test');
    file = File('${dir.path}/logs/app.log');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('FileAppLog', () {
    test('writes a stamped, level-and-category tagged line', () {
      FileAppLog(file).info('app', 'Grid starting');

      final text = file.readAsStringSync();
      expect(text, contains('INFO '));
      expect(text, contains('app'));
      expect(text, contains('Grid starting'));
    });

    test('creates the logs directory on demand', () {
      expect(file.parent.existsSync(), isFalse);
      FileAppLog(file).info('app', 'hi');
      expect(file.existsSync(), isTrue);
    });

    test('appends the error and an indented stack trace on a failure', () {
      FileAppLog(file).failure(
        'flutter',
        'render overflow',
        error: StateError('bad'),
        stackTrace: StackTrace.fromString('#0 first\n#1 second'),
      );

      final text = file.readAsStringSync();
      expect(text, contains('ERROR'));
      expect(text, contains('render overflow'));
      expect(text, contains('err=Bad state: bad'));
      expect(text, contains('    #0 first'));
      expect(text, contains('    #1 second'));
    });

    test('every level renders a distinct tag', () {
      FileAppLog(file)
        ..debug('cli', 'd')
        ..info('cli', 'i')
        ..warn('cli', 'w')
        ..failure('cli', 'e');

      final text = file.readAsStringSync();
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
