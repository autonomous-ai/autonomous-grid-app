import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/task_inbox_store.dart';

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_task_inbox_test');
    file = File('${tmp.path}/app/task_inbox.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        taskInboxStoreProvider.overrideWithValue(TaskInboxStore(file: file)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  final at = DateTime.utc(2026, 8, 5, 8);

  group('what the newest run said', () {
    test('survives a restart — the row must say it before it is opened', () {
      TaskInboxStore(file: file).save({
        'daily-brief': TaskResultDigest(
          summary: 'Three PRs need review',
          at: at,
        ),
      });

      final loaded = TaskInboxStore(file: file).load();
      expect(loaded['daily-brief']?.summary, 'Three PRs need review');
      expect(loaded['daily-brief']?.at, at);
    });

    test('a newer run replaces the headline, it does not stack up', () {
      final c = container();
      final inbox = c.read(taskInboxProvider.notifier);
      inbox.record('daily-brief', TaskResultDigest(summary: 'Old', at: at));
      inbox.record(
        'daily-brief',
        TaskResultDigest(summary: 'New', at: at.add(const Duration(days: 1))),
      );

      expect(c.read(taskInboxProvider), hasLength(1));
      expect(c.read(taskInboxProvider)['daily-brief']?.summary, 'New');
    });

    test('a deleted task takes its headline with it', () {
      final c = container();
      final inbox = c.read(taskInboxProvider.notifier);
      inbox.record('gone', TaskResultDigest(summary: 'Was here', at: at));
      inbox.forget('gone');

      expect(c.read(taskInboxProvider), isEmpty);
      expect(TaskInboxStore(file: file).load(), isEmpty);
    });
  });

  group('a store that cannot be trusted', () {
    test('an unreadable file costs a line of detail, not the screen', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json at all');

      expect(TaskInboxStore(file: file).load(), isEmpty);
    });

    test('one malformed entry drops that row and keeps the rest', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''
{
  "good": {"summary": "Kept", "at": "2026-08-05T08:00:00.000Z"},
  "undated": {"summary": "No idea when this ran"},
  "wrong-shape": "just a string"
}
''');

      final loaded = TaskInboxStore(file: file).load();
      expect(loaded.keys, ['good']);
      expect(loaded['good']?.summary, 'Kept');
    });

    test('a run that said nothing is kept as an empty headline, not dropped —'
        ' the row still has a time to show', () {
      TaskInboxStore(
        file: file,
      ).save({'quiet': TaskResultDigest(summary: '', at: at)});

      expect(TaskInboxStore(file: file).load()['quiet']?.summary, isEmpty);
    });
  });
}
