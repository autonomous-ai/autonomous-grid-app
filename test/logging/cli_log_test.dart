import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/cli_log.dart';
import 'package:grid_app/infrastructure/logging/log_file.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('grid_cli_log_test');
    file = File('${dir.path}/logs/app_cli.log');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('FileCliLog', () {
    test('writes a header, output lines and an outcome footer', () {
      final log = FileCliLog(file);
      final entry = log.begin('grid --remote login');
      entry.output('scan devices');
      entry.output('boom', isError: true);
      entry.end(exitCode: 0);

      final text = file.readAsStringSync();
      expect(text, contains(r'$ grid --remote login'));
      expect(text, contains('#1 | scan devices'));
      expect(text, contains('#1 ! boom'));
      expect(text, contains('#1 ← done exit=0'));
    });

    test('creates the logs directory on demand', () {
      expect(file.parent.existsSync(), isFalse);
      FileCliLog(file).begin('grid --version').end(exitCode: 0);
      expect(file.existsSync(), isTrue);
    });

    test('tags concurrent calls with distinct ids', () {
      final log = FileCliLog(file);
      final a = log.begin('grid a');
      final b = log.begin('grid b');
      a.output('from-a');
      b.output('from-b');
      a.end(exitCode: 0);
      b.end(exitCode: 1);

      final text = file.readAsStringSync();
      expect(text, contains('#1 | from-a'));
      expect(text, contains('#2 | from-b'));
      expect(text, contains('#1 ← done exit=0'));
      expect(text, contains('#2 ← done exit=1'));
    });

    test('end is idempotent — a second close is ignored', () {
      final log = FileCliLog(file);
      final entry = log.begin('grid sync');
      entry.end(exitCode: 0);
      entry.end(error: 'late');
      entry.output('too late');

      final done = '← done'.allMatches(file.readAsStringSync()).length;
      expect(done, 1);
    });

    test('records the error on a failed call', () {
      FileCliLog(file).begin('grid login').end(error: 'network down');
      expect(file.readAsStringSync(), contains('error: network down'));
    });
  });

  group('LogFile', () {
    test('rotates to a .old sibling once past maxBytes', () {
      final logFile = LogFile(file, maxBytes: 64);
      logFile.append('x' * 100); // now over the threshold
      logFile.rotateIfLarge();
      logFile.append('fresh');

      expect(File('${file.path}.old').existsSync(), isTrue);
      expect(file.readAsStringSync().trim(), 'fresh');
    });

    test('swallows IO errors instead of throwing', () {
      // Point at a path whose parent is a file, so directory creation fails.
      final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
      final bad = LogFile(File('${blocker.path}/nested.log'));
      expect(() => bad.append('hi'), returnsNormally);
    });
  });

  group('log format helpers', () {
    test('logClock and logStamp zero-pad', () {
      final t = DateTime(2026, 7, 6, 9, 5, 3);
      expect(logClock(t), '09:05:03');
      expect(logStamp(t), '2026-07-06 09:05:03');
    });

    test('logDuration switches to minutes past 60s', () {
      expect(logDuration(const Duration(seconds: 42)), '42s');
      expect(logDuration(const Duration(seconds: 95)), '1m35s');
    });
  });
}
