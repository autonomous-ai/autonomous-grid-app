import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_task.dart';
import 'package:grid_app/features/code/logic/task_event.dart';
import 'package:grid_app/features/code/logic/task_event_lines.dart';
import 'package:grid_app/features/code/logic/task_steps_store.dart';

void main() {
  late Directory tmp;
  late TaskStepsStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_task_steps');
    store = TaskStepsStore(directory: tmp);
  });
  tearDown(() => tmp.delete(recursive: true));

  group('turning a run into lines', () {
    test('a tool call, the prose around it and the verdict all become lines, '
        'keeping the seq they came from', () {
      final lines = taskFeedLines([
        const TaskOutput(1, 'Looking at the parser.'),
        const TaskToolUse(2, tool: 'read', path: 'lib/parser.dart'),
        const TaskTerminal(3, state: TaskState.completed),
      ]);

      expect(lines.map((line) => line.seq), [1, 2, 3]);
      expect(lines[1].text, 'read  lib/parser.dart');
      expect(lines[1].tone, TaskLineTone.step);
      expect(lines.last.tone, TaskLineTone.verdict);
    });

    test('the events with nothing to show leave no line — a successful tool '
        'result and a tree snapshot would double the length of the record with '
        'rows nobody reads', () {
      final lines = taskFeedLines([
        const TaskToolResult(1, isError: false),
        const TaskTree(2, paths: ['a.dart']),
        const TaskOutput(3, '   '),
      ]);

      expect(lines, isEmpty);
    });
  });

  group('keeping a finished run', () {
    test('what was written is what reads back — the whole point being that it '
        'is still there tomorrow', () async {
      await store.save(
        'task-1',
        taskFeedLines(const [
          TaskOutput(1, 'Fixed the parser.'),
          TaskToolUse(2, tool: 'edit', path: 'lib/parser.dart'),
        ]),
      );

      final run = await store.load('task-1');

      expect(run.isEmpty, isFalse);
      expect(run.lines.map((line) => line.text), [
        'Fixed the parser.',
        'edit  lib/parser.dart',
      ]);
      expect(run.lines.first.tone, TaskLineTone.prose);
      expect(run.dropped, 0);
    });

    test('a task nobody kept reads as nothing kept, not as an error — every '
        'task that ran before this existed is one of those', () async {
      final run = await store.load('never-watched');
      expect(run.isEmpty, isTrue);
      expect(run.dropped, 0);
    });

    test('a run longer than the cap keeps its end and counts what it cut, so '
        'the record never pretends the run started in the middle', () async {
      final long = [
        for (var seq = 0; seq < TaskStepsStore.maxLines + 25; seq++)
          TaskToolUse(seq, tool: 'read', path: 'file$seq.dart'),
      ];

      await store.save('task-long', taskFeedLines(long));
      final run = await store.load('task-long');

      expect(run.lines, hasLength(TaskStepsStore.maxLines));
      expect(run.dropped, 25);
      // The end is what was kept, so the last thing it did is the last line.
      expect(run.lines.last.text, endsWith('file${long.length - 1}.dart'));
    });

    test('a run with nothing worth showing writes no file at all', () async {
      await store.save('task-empty', const []);
      expect(await store.load('task-empty'), isA<StoredTaskRun>());
      expect((await store.load('task-empty')).isEmpty, isTrue);
    });

    test('a hand-edited file reads as nothing kept rather than taking the '
        'screen down — the result text is still there either way', () async {
      await File('${tmp.path}/task-broken.json').writeAsString('{not json');
      expect((await store.load('task-broken')).isEmpty, isTrue);
    });
  });
}
