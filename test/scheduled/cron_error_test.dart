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
}
