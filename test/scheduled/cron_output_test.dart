import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/cron_output.dart';

/// A scheduled run's `.md` is Hermes boilerplate wrapped around the answer. These
/// pin that the preview shows the answer, not the job id and the raw cron line.
void main() {
  group('cronOutputBody', () {
    test('returns only what is under ## Response, dropping the header', () {
      const raw = '''
# Cron Job: Daily digest

**Job ID:** 8d3f11133616
**Run Time:** 2026-07-24 11:02:28
**Schedule:** 0 8 * * 1-5

## Prompt

Summarise my open PRs.

## Response

Three PRs need review, two are ready to merge.''';

      final body = cronOutputBody(raw);
      expect(body, 'Three PRs need review, two are ready to merge.');
      // None of the metadata a non-technical reader can't use survives.
      expect(body, isNot(contains('Job ID')));
      expect(body, isNot(contains('0 8 * * 1-5')));
      expect(body, isNot(contains('## Prompt')));
    });

    test('a failed run shows what went wrong, not the metadata', () {
      const raw = '''
# Cron Job: Daily digest (FAILED)

**Job ID:** x
**Schedule:** 0 8 * * 1-5

## Prompt

Do the thing.

## Error

```
TimeoutError: model did not respond
```''';

      final body = cronOutputBody(raw);
      expect(body, contains('TimeoutError'));
      expect(body, isNot(contains('Job ID')));
    });

    test('a run that keeps its answer inside prose is not cut at it', () {
      // "## Response" here is part of the answer, not the section divider — the
      // heading is anchored to a whole line, so the real divider still wins.
      const raw = '''
# Cron Job: Notes

**Job ID:** x

## Response

I filed it under the "## Response times" section of the doc.''';

      expect(
        cronOutputBody(raw),
        'I filed it under the "## Response times" section of the doc.',
      );
    });

    test('output that does not follow the template is shown whole', () {
      // A script job writes its stdout straight after the metadata — no answer
      // heading — so nothing is hidden behind a format we did not expect.
      const raw = 'Backup finished: 412 files, 1.2 GB.';
      expect(cronOutputBody(raw), 'Backup finished: 412 files, 1.2 GB.');
    });
  });
}
