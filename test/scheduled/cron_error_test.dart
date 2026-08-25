import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/cron_error.dart';
import 'package:grid_app/shared/copy/setup_hints.dart';

void main() {
  group('describeCronRunError', () {
    test('turns the model-drift spend guard into a plain paused message with a '
        'next step, so the user never faces a raw RuntimeError', () {
      const raw =
          "RuntimeError: Skipped to prevent unintended spend: global inference "
          "config drifted since this job was created (model "
          "'deepreinforce-ai/ornith-1.0-397b' -> 'deepreinforce-ai/"
          "ornith-1.0-35b'), and this job is unpinned. No inference call was "
          "made. To run on the new config, pin it explicitly: `cronjob "
          "action=update job_id=30528b3ed43b provider=<provider> "
          "model=<model>` (or pin the original values to keep them). See #44585.";

      final result = describeCronRunError(raw);

      expect(result.summary, contains('Paused'));
      expect(result.summary.toLowerCase(), contains('model'));
      // The engineering detail (RuntimeError, job id, `cronjob action=update`,
      // the issue number) must not leak into the user-facing summary.
      expect(result.summary, isNot(contains('RuntimeError')));
      expect(result.summary, isNot(contains('cronjob')));
      expect(result.summary, isNot(contains('#44585')));
      // The next step is the action the task's own screen offers, not the old
      // "delete it and start over" that cost the user the task's results.
      expect(result.hint, contains('Use the current model'));
    });

    test('matches the guard even when only the unpinned/drift wording is '
        'present, so a reworded provider drift is still humanized', () {
      const raw =
          "Job skipped: provider 'openai' -> 'nous' drifted and the job is "
          'unpinned.';

      final result = describeCronRunError(raw);

      expect(result.summary, contains('Paused'));
      expect(result.hint, isNotNull);
    });

    test('turns a "no model configured" run into a plain message with a next '
        'step, so the user never faces the raw RuntimeError and env dump', () {
      const raw =
          "RuntimeError: Cron job 'latest news today' has no model "
          "configured (job.model=None, HERMES_MODEL='', config.yaml "
          'model.default missing or empty). Set a per-job model via `cronjob '
          'action=update job_id=73ee873b963f model=<name>` or set a default '
          'with `hermes model <name>`.';

      final result = describeCronRunError(raw);

      expect(result.summary.toLowerCase(), contains('no ai model'));
      // None of the engineering detail leaks into the user-facing summary.
      expect(result.summary, isNot(contains('RuntimeError')));
      expect(result.summary, isNot(contains('cronjob')));
      expect(result.summary, isNot(contains('HERMES_MODEL')));
      expect(result.summary, isNot(contains('config.yaml')));
      expect(result.hint, isNotNull);
      expect(result.hint, contains('create it again'));
    });

    test('turns the scheduler\'s idle watchdog into a plain "it went quiet" '
        'line, so the user is not shown a raw TimeoutError and a seconds '
        'count', () {
      const raw =
          "TimeoutError: Cron job 'Daily report' idle for 936s (limit 600s) — "
          'last activity: waiting for non-streaming API response';

      final result = describeCronRunError(raw);

      expect(result.summary, isNot(contains('TimeoutError')));
      expect(result.summary, isNot(contains('936')));
      expect(result.summary, isNot(contains('non-streaming')));
      // It is one bad run, not a dead task — the copy has to say so, or the
      // user pauses a task that would have answered tomorrow.
      expect(result.summary, contains('try again'));
      expect(result.hint, isNotNull);
    });

    test('blames the grid, not the model, when the relay had no provider to '
        'hand the run to — and names the grid the task actually runs on', () {
      const raw =
          'RuntimeError: HTTP 503: {"detail":"No providers available for this '
          'model"}';

      final result = describeCronRunError(
        raw,
        taskGrid: 'hp-1-1',
        currentGrid: 'hp-1-1',
      );

      expect(result.summary, isNot(contains('RuntimeError')));
      expect(result.summary, isNot(contains('503')));
      expect(result.summary, contains('hp-1-1'));
      // The fix is somebody sharing a model, so the hint has to send the user
      // where sharing is set up — the shared sentence, not a second wording.
      expect(result.hint, contains(kModelEnginesPlace));
    });

    test('says so when the task is pointed at a different grid than the one on '
        'screen — the failure that reads like a model problem and is not', () {
      final result = describeCronRunError(
        'RuntimeError: HTTP 503: {"detail":"No providers available for this '
        'model"}',
        taskGrid: 'hp-1-1',
        currentGrid: 'autonomous.ai',
      );

      expect(result.summary, contains('hp-1-1'));
      expect(result.hint, contains('autonomous.ai'));
      // Sending them to share a model here would be the wrong fix: this grid
      // has models, the task is simply not on it.
      expect(result.hint, isNot(contains(kModelEnginesPlace)));
    });

    test('still explains a no-provider failure when the grid is unknown, '
        'rather than naming a grid it cannot know', () {
      final result = describeCronRunError(
        'RuntimeError: HTTP 503: {"detail":"No providers available for this '
        'model"}',
      );

      expect(result.summary, contains('sharing AI'));
      expect(result.summary, isNot(contains('"')));
      expect(result.hint, contains(kModelEnginesPlace));
    });

    test(
      'passes an unrecognized error through verbatim so no detail is lost',
      () {
        const raw = 'ConnectionError: relay unreachable at 127.0.0.1:8080';

        final result = describeCronRunError(raw);

        expect(result.summary, raw);
        expect(result.hint, isNull);
      },
    );

    test('trims surrounding whitespace on an unrecognized error', () {
      final result = describeCronRunError('  boom  ');

      expect(result.summary, 'boom');
    });
  });

  group('isBlockingCronError', () {
    test('a model-drift skip and a missing model both count as blocking, so '
        'the status reads "Won\'t run" rather than a hopeful "last run '
        'failed"', () {
      expect(
        isBlockingCronError(
          'Skipped to prevent unintended spend: the job is unpinned and the '
          'model drifted.',
        ),
        isTrue,
      );
      expect(
        isBlockingCronError("Cron job 'x' has no model configured."),
        isTrue,
      );
    });

    test('a one-off failure that could pass next time is not blocking', () {
      expect(
        isBlockingCronError('ConnectionError: relay unreachable'),
        isFalse,
      );
    });

    test('an idle timeout is not blocking: the run was too slow once, and the '
        'task still has a next run to answer on', () {
      expect(
        isBlockingCronError(
          "TimeoutError: Cron job 'Daily report' idle for 936s (limit 600s) "
          '— last activity: waiting for non-streaming API response',
        ),
        isFalse,
      );
    });
  });
}
