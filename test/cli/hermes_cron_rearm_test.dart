import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_rearm.dart';

/// A job as Hermes stores it, with only the fields the drift guard reads.
String _store(List<Map<String, Object?>> jobs) =>
    jsonEncode({'jobs': jobs, 'updated_at': '2026-07-30T08:00:00+07:00'});

const _driftError =
    'RuntimeError: Skipped to prevent unintended spend: global inference config '
    "drifted since this job was created (model 'auto' -> 'minimax/minimax-m3'), "
    'and this job is unpinned. No inference call was made.';

Map<String, Object?> _job({
  String id = 'abc123',
  Object? model,
  Object? snapshot = 'auto',
  Object? lastError = _driftError,
}) => {
  'id': id,
  'name': 'Daily digest',
  'model': model,
  'model_snapshot': snapshot,
  'last_error': lastError,
};

void main() {
  group('cronRearmTargets', () {
    test('a task stranded on the model it was created with is re-armed, and '
        'its stale skip cleared with it', () {
      final targets = cronRearmTargets(
        _store([_job()]),
        model: 'minimax/minimax-m3',
      );

      expect(targets, hasLength(1));
      expect(targets.single.id, 'abc123');
      expect(
        targets.single.clearError,
        isTrue,
        reason: 'the task will run now, so it must stop saying it won\'t',
      );
    });

    test('a task already following the current model is left alone — nothing '
        'to fix, nothing to write', () {
      final targets = cronRearmTargets(
        _store([_job(snapshot: 'minimax/minimax-m3', lastError: null)]),
        model: 'minimax/minimax-m3',
      );

      expect(targets, isEmpty);
    });

    test('a pinned task keeps the model somebody chose for it', () {
      final targets = cronRearmTargets(
        _store([_job(model: 'maker/pinned')]),
        model: 'minimax/minimax-m3',
      );

      expect(targets, isEmpty);
    });

    test('a task with no snapshot is not touched — the scheduler never blocks '
        'it, so there is nothing to unblock', () {
      final targets = cronRearmTargets(
        _store([_job(snapshot: null, lastError: null)]),
        model: 'minimax/minimax-m3',
      );

      expect(targets, isEmpty);
    });

    test('a failure that is not the model skip stays on the task — it is real '
        'history, not something a re-arm fixed', () {
      final targets = cronRearmTargets(
        _store([_job(lastError: 'ConnectionError: relay unreachable')]),
        model: 'minimax/minimax-m3',
      );

      expect(targets.single.clearError, isFalse);
    });

    test('asked about one task, it is re-armed even when its snapshot already '
        'matches — that is how a stale error clears', () {
      final targets = cronRearmTargets(
        _store([
          _job(id: 'mine', snapshot: 'minimax/minimax-m3'),
          _job(id: 'other'),
        ]),
        model: 'minimax/minimax-m3',
        onlyJobId: 'mine',
      );

      expect(targets.map((t) => t.id), ['mine']);
      expect(targets.single.clearError, isTrue);
    });

    test('with no model to follow, nothing is written — a blank model would '
        'pin every task to nothing', () {
      expect(cronRearmTargets(_store([_job()]), model: '  '), isEmpty);
    });

    test('a store Hermes has reshaped is skipped, not thrown — pointing at a '
        'grid must not fail over the scheduler', () {
      expect(cronRearmTargets('not json', model: 'm'), isEmpty);
      expect(cronRearmTargets('{"jobs": "nope"}', model: 'm'), isEmpty);
      expect(cronRearmTargets(_store([{}]), model: 'm'), isEmpty);
    });
  });

  group('cronRearmArgs', () {
    test('what to touch travels as data, so the program applies a decision it '
        'never has to make', () {
      final args = cronRearmArgs(
        model: ' minimax/minimax-m3 ',
        targets: const [
          (id: 'a1', clearError: true),
          (id: 'b2', clearError: false),
        ],
      );

      expect(args[0], '-c');
      expect(args[1], kCronRearmProgram);
      expect(args[2], 'minimax/minimax-m3');
      expect(jsonDecode(args[3]), [
        {'id': 'a1', 'clear_error': true},
        {'id': 'b2', 'clear_error': false},
      ]);
    });

    test('the program pins before it unpins — a tick that fires between the '
        'two writes must run on the model we meant', () {
      final pin = kCronRearmProgram.indexOf('{"model": model}');
      final unpin = kCronRearmProgram.indexOf('{"model": None}');

      expect(pin, isNonNegative);
      expect(unpin, greaterThan(pin));
    });
  });

  group('cronRearmFailure', () {
    test('the last line of a traceback is the one that names the failure', () {
      const traceback = '''
Traceback (most recent call last):
  File "<string>", line 5, in <module>
    update_job(job_id, {"model": model})
ValueError: Cron job field(s) cannot be updated: id
''';

      expect(
        cronRearmFailure(traceback, ''),
        'ValueError: Cron job field(s) cannot be updated: id',
      );
    });

    test('a process that failed on stdout still has something to show', () {
      expect(cronRearmFailure('', 'no such job'), 'no such job');
    });

    test('a silent failure still gets a sentence — the user is owed one', () {
      expect(cronRearmFailure('  ', ''), 'the scheduler rejected the change');
    });
  });

  group('HermesCronRearm', () {
    test('an install this cannot reach into says so, with a way out, instead '
        'of leaving the task silently blocked', () async {
      const rearm = HermesCronRearm(
        binPath: '/nowhere/hermes',
        home: '/nowhere',
      );

      expect(
        () => rearm.apply(_store([_job()]), 'minimax/minimax-m3'),
        throwsA(
          isA<CronRearmException>().having(
            (e) => e.message,
            'message',
            kCronRearmUnavailable,
          ),
        ),
      );
    });

    test('nothing stranded means no process is spawned at all', () async {
      const rearm = HermesCronRearm(
        binPath: '/nowhere/hermes',
        home: '/nowhere',
      );

      expect(
        await rearm.apply(
          _store([_job(snapshot: 'minimax/minimax-m3', lastError: null)]),
          'minimax/minimax-m3',
        ),
        isEmpty,
      );
    });
  });
}
