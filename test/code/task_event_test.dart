import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_task.dart';
import 'package:grid_app/features/code/logic/task_event.dart';
import 'package:grid_app/features/code/logic/task_event_lines.dart';

String _line(int seq, Map<String, dynamic> event) =>
    jsonEncode({'seq': seq, 'event': event});

void main() {
  group('parsing what `grid task follow --json` prints', () {
    test('a line that is not an event never takes the stream down', () {
      // The CLI puts its own diagnostics on stderr, but a viewer may not die on
      // a stray notice or a blank line either way.
      expect(parseTaskEvent(''), isNull);
      expect(parseTaskEvent('connection lost; reattaching at seq 3'), isNull);
      expect(parseTaskEvent('{not json'), isNull);
      expect(parseTaskEvent('{"seq": 1}'), isNull);
    });

    test('an event type this build has never seen is kept, not dropped', () {
      // Types grow. A viewer that rendered only what it knew would show a user
      // nothing while the grid faithfully streamed them what they asked for.
      final event = parseTaskEvent(_line(7, {'type': 'task.something_new'}));
      expect(event, isA<TaskUnknownEvent>());
      expect(event!.seq, 7);
    });

    test('a terminal event carries the state the task ended in', () {
      final event =
          parseTaskEvent(_line(9, {'type': 'task.terminal', 'state': 'failed'}))
              as TaskTerminal;
      expect(event.state, TaskState.failed);
    });

    test('queue_expired is recognised on the terminal event too', () {
      final event =
          parseTaskEvent(
                _line(9, {
                  'type': 'task.terminal',
                  'state': 'timed_out',
                  'error': 'queue_expired',
                }),
              )
              as TaskTerminal;
      expect(event.queueExpired, isTrue);
    });
  });

  group('a workspace snapshot is only compared when it is provably whole', () {
    test('a complete tree is marked complete', () {
      final tree =
          parseTaskEvent(
                _line(2, {
                  'type': 'task.tree',
                  'paths': ['a.py', 'b.py'],
                  'total': 2,
                }),
              )
              as TaskTree;
      expect(tree.complete, isTrue);
    });

    test('a truncated tree is not, so nothing is reported as deleted', () {
      // A path missing from a partial snapshot is a path we were not given.
      // Calling it removed would be a confident, wrong claim that the agent
      // deleted the user's file.
      final tree =
          parseTaskEvent(
                _line(2, {
                  'type': 'task.tree',
                  'paths': ['a.py'],
                  'total': 200,
                  'truncated': true,
                }),
              )
              as TaskTree;
      expect(tree.complete, isFalse);
    });

    test('an entry that is not a string makes the whole snapshot partial', () {
      // Silently dropping it would leave a SHORTER list that looks complete.
      final tree =
          parseTaskEvent(
                _line(2, {
                  'type': 'task.tree',
                  'paths': ['a.py', 42],
                  'total': 2,
                }),
              )
              as TaskTree;
      expect(tree.paths, ['a.py']);
      expect(tree.complete, isFalse);
    });
  });

  group('what a person reads', () {
    test(
      'a successful tool result says nothing — hundreds arrive per task',
      () {
        expect(taskEventLine(const TaskToolResult(3, isError: false)), isNull);
      },
    );

    test('a failed one does, because that is the only news in the pair', () {
      expect(
        taskEventLine(const TaskToolResult(3, isError: true))?.tone,
        TaskLineTone.note,
      );
    });

    test('a tool call reads as a step, with its path when it has one', () {
      final line = taskEventLine(
        const TaskToolUse(4, tool: 'Edit', path: 'src/app.py'),
      )!;
      expect(line.text, 'Edit  src/app.py');
      expect(line.tone, TaskLineTone.step);
    });

    test('a retry says the attempt was lost and that it starts over', () {
      // The only copy of this fact the person who submitted the task ever
      // gets: without it, a repeated run reads as the agent looping.
      final line = taskEventLine(
        const TaskRetry(5, reason: 'its lease lapsed'),
      )!;
      expect(line.text, contains('starting again'));
    });

    test('a fresh session warns that earlier conversation is gone', () {
      final line = taskEventLine(
        const TaskSessionReset(6, 'the transcript could not be used'),
      )!;
      expect(line.text, contains('will not remember'));
    });

    test('the provider’s subscription status is passed through verbatim', () {
      // What a status means is decided on the provider; a second reading here
      // is a second thing to disagree.
      final line = taskEventLine(
        const TaskCapacity(7, limitType: 'five_hour', status: 'allowed'),
      )!;
      expect(line.text, contains('allowed'));
    });

    test('a tree is not a feed line — it is a snapshot re-sent in full', () {
      expect(
        taskEventLine(const TaskTree(8, paths: ['a.py'], total: 1)),
        isNull,
      );
    });

    test('empty agent output is dropped rather than shown as a blank row', () {
      expect(taskEventLine(const TaskOutput(9, '   \n')), isNull);
    });
  });

  group('how it ended', () {
    test('never claimed is told apart from ran-out-of-time while working', () {
      // "Ran out of time" reads as "the task hung", and this one never started:
      // the action is to add a computer, not to fix the prompt.
      final unclaimed = terminalLine(
        const TaskTerminal(
          1,
          state: TaskState.timedOut,
          error: 'queue_expired',
        ),
      );
      expect(unclaimed, contains('short of machines'));

      final overran = terminalLine(
        const TaskTerminal(1, state: TaskState.timedOut),
      );
      expect(overran, contains('while working'));
    });

    test('a failure carries the grid’s own reason when there is one', () {
      expect(
        terminalLine(
          const TaskTerminal(
            1,
            state: TaskState.failed,
            error: 'the agent exited 1',
          ),
        ),
        contains('the agent exited 1'),
      );
    });
  });
}
