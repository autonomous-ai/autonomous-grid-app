import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/cron_error.dart';

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
      expect(result.hint, isNotNull);
      expect(result.hint, contains('create it again'));
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
          "RuntimeError: Cron job 'tin mới nhất hôm nay' has no model "
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
  });
}
