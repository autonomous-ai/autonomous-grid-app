import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/cli_log.dart';
import 'package:grid_app/infrastructure/logging/log_file.dart';

void main() {
  late Directory dir;
  late Directory logs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('grid_cli_log_test');
    logs = Directory('${dir.path}/logs');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // A fixed clock so the dated filename is deterministic across the run.
  DailyLogFile daily(String base) =>
      DailyLogFile(logs, base, clock: () => DateTime(2026, 7, 10, 9, 5, 3));

  group('FileCliLog', () {
    test('writes a header, output lines and an outcome footer', () {
      final file = daily('app_cli');
      final entry = FileCliLog(file).begin('grid --remote login');
      entry.output('scan devices');
      entry.output('boom', isError: true);
      entry.end(exitCode: 0);

      final text = file.currentFile.readAsStringSync();
      expect(text, contains(r'$ grid --remote login'));
      expect(text, contains('#1 | scan devices'));
      expect(text, contains('#1 ! boom'));
      expect(text, contains('#1 ← done exit=0'));
    });

    test('creates the logs directory on demand', () {
      final file = daily('app_cli');
      expect(logs.existsSync(), isFalse);
      FileCliLog(file).begin('grid --version').end(exitCode: 0);
      expect(file.currentFile.existsSync(), isTrue);
    });

    test('tags concurrent calls with distinct ids', () {
      final file = daily('app_cli');
      final log = FileCliLog(file);
      final a = log.begin('grid a');
      final b = log.begin('grid b');
      a.output('from-a');
      b.output('from-b');
      a.end(exitCode: 0);
      b.end(exitCode: 1);

      final text = file.currentFile.readAsStringSync();
      expect(text, contains('#1 | from-a'));
      expect(text, contains('#2 | from-b'));
      expect(text, contains('#1 ← done exit=0'));
      expect(text, contains('#2 ← done exit=1'));
    });

    test('end is idempotent — a second close is ignored', () {
      final file = daily('app_cli');
      final entry = FileCliLog(file).begin('grid sync');
      entry.end(exitCode: 0);
      entry.end(error: 'late');
      entry.output('too late');

      final done = '← done'.allMatches(file.currentFile.readAsStringSync());
      expect(done.length, 1);
    });

    test('records the error on a failed call', () {
      final file = daily('app_cli');
      FileCliLog(file).begin('grid login').end(error: 'network down');
      expect(
        file.currentFile.readAsStringSync(),
        contains('error: network down'),
      );
    });
  });

  group('DailyLogFile', () {
    test('writes to a per-day file named <base>-YYYYMMDD.log', () {
      final file = daily('app');
      file.append('today');

      expect(File('${logs.path}/app-20260710.log').existsSync(), isTrue);
      expect(dailyLogName('app', DateTime(2026, 7, 10)), 'app-20260710.log');
    });

    test('prunes this base\'s files older than the retention window', () {
      logs.createSync(recursive: true);
      // 14-day window on 2026-07-10 → keep >= 2026-06-26, drop older.
      File('${logs.path}/app-20260101.log').writeAsStringSync('old');
      File('${logs.path}/app-20260705.log').writeAsStringSync('recent');
      // A different base must never be touched by app's pruning.
      File('${logs.path}/app_cli-20260101.log').writeAsStringSync('other');

      DailyLogFile(
        logs,
        'app',
        retentionDays: 14,
        clock: () => DateTime(2026, 7, 10),
      ).append('now');

      expect(File('${logs.path}/app-20260101.log').existsSync(), isFalse);
      expect(File('${logs.path}/app-20260705.log').existsSync(), isTrue);
      expect(File('${logs.path}/app-20260710.log').existsSync(), isTrue);
      expect(File('${logs.path}/app_cli-20260101.log').existsSync(), isTrue);
    });

    test('retentionDays <= 0 keeps every day', () {
      logs.createSync(recursive: true);
      File('${logs.path}/app-20200101.log').writeAsStringSync('ancient');

      DailyLogFile(
        logs,
        'app',
        retentionDays: 0,
        clock: () => DateTime(2026, 7, 10),
      ).append('now');

      expect(File('${logs.path}/app-20200101.log').existsSync(), isTrue);
    });

    test('swallows IO errors instead of throwing', () {
      // Point the directory at a path whose parent is a file, so creation fails.
      final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
      final bad = DailyLogFile(Directory('${blocker.path}/nested'), 'app');
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
