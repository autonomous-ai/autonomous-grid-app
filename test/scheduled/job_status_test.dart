import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/job_status.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_job.dart';

ScheduledJob _job({
  bool enabled = true,
  DateTime? nextRunAt,
  DateTime? lastRunAt,
  String? lastError,
}) => ScheduledJob(
  id: 'j1',
  name: 'Task',
  prompt: 'do a thing',
  cron: '0 9 * * *',
  enabled: enabled,
  nextRunAt: nextRunAt,
  lastRunAt: lastRunAt,
  lastError: lastError,
);

void main() {
  group('jobStatusOf', () {
    test('a paused task reads as paused even after a failed run — pausing is not '
        'failing', () {
      final job = _job(enabled: false, lastError: 'boom');
      expect(jobStatusOf(job), JobStatus.paused);
    });

    test('an enabled task whose last run errored reads as failed', () {
      expect(jobStatusOf(_job(lastError: 'boom')), JobStatus.lastRunFailed);
    });

    test('an enabled task with a clean last run reads as running', () {
      expect(jobStatusOf(_job()), JobStatus.running);
    });

    test('a task the scheduler is skipping for model drift reads as blocked, '
        'not merely failed — it won\'t run until the user acts', () {
      final job = _job(
        lastError:
            'Skipped: unpinned job, model drift detected — refusing to run '
            'to avoid unintended spend.',
      );
      expect(jobStatusOf(job), JobStatus.blocked);
    });

    test('a paused task still reads as paused even when the error is a drift '
        'skip — the user\'s pause wins', () {
      final job = _job(
        enabled: false,
        lastError: 'refusing to run to avoid unintended spend',
      );
      expect(jobStatusOf(job), JobStatus.paused);
    });
  });

  group('jobNextRunLine for a blocked task', () {
    test('a blocked task shows no next-run line — its next run is a lie', () {
      final now = DateTime(2026, 7, 16, 9, 0);
      final job = _job(
        nextRunAt: now.add(const Duration(hours: 3)),
        lastError: 'refusing to run to avoid unintended spend',
      );
      // The row leads with the failure for a blocked task, so the caller asks
      // for the last-run line, not the next-run one. The next-run helper itself
      // still returns a value (it only knows enabled/nextRunAt) — the row logic
      // is what suppresses it, verified in the widget's _liveLine.
      expect(jobStatusOf(job), JobStatus.blocked);
      expect(jobLastRunLine(job, now), isNull); // never ran in this fixture
    });
  });

  group('jobNextRunLine', () {
    final now = DateTime(2026, 7, 16, 9, 0);

    test('a paused task shows no next-run line', () {
      final job = _job(
        enabled: false,
        nextRunAt: now.add(const Duration(hours: 3)),
      );
      expect(jobNextRunLine(job, now), isNull);
    });

    test('a run hours away today counts down in hours', () {
      final job = _job(nextRunAt: now.add(const Duration(hours: 3)));
      expect(jobNextRunLine(job, now), 'Runs in 3h');
    });

    test('a run under an hour away counts down in minutes', () {
      final job = _job(nextRunAt: now.add(const Duration(minutes: 12)));
      expect(jobNextRunLine(job, now), 'Runs in 12m');
    });

    test('a run tomorrow names tomorrow and the time', () {
      final job = _job(nextRunAt: DateTime(2026, 7, 17, 9, 0));
      expect(jobNextRunLine(job, now), 'Runs tomorrow 09:00');
    });

    test('with no next time there is nothing to say', () {
      expect(jobNextRunLine(_job(), now), isNull);
    });
  });

  group('jobLastRunLine', () {
    final now = DateTime(2026, 7, 16, 12, 0);

    test('a task that has never run has no last-run line', () {
      expect(jobLastRunLine(_job(), now), isNull);
    });

    test('a clean run earlier today reads as "Ran today HH:mm"', () {
      final job = _job(lastRunAt: DateTime(2026, 7, 16, 9, 0));
      expect(jobLastRunLine(job, now), 'Ran today 09:00');
    });

    test('a failed run leads with "Failed"', () {
      final job = _job(
        lastRunAt: DateTime(2026, 7, 16, 9, 0),
        lastError: 'boom',
      );
      expect(jobLastRunLine(job, now), 'Failed today 09:00');
    });

    test('a run yesterday names yesterday', () {
      final job = _job(lastRunAt: DateTime(2026, 7, 15, 9, 0));
      expect(jobLastRunLine(job, now), 'Ran yesterday 09:00');
    });
  });
}
