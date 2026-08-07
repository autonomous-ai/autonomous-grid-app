import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/commit_message_writer.dart';
import 'package:grid_app/features/review/logic/review_argv.dart';

void main() {
  group('commitDiffArgv', () {
    test('describes what the commit will actually carry — the index when only '
        'the ticked files go in', () {
      expect(commitDiffArgv(includeUnticked: false, hasCommits: true), [
        'diff',
        '--cached',
      ]);
    });

    test('and everything since the last commit when the toggle sweeps the '
        'rest in, or the message would describe the wrong change', () {
      expect(commitDiffArgv(includeUnticked: true, hasCommits: true), [
        'diff',
        'HEAD',
      ]);
    });

    test('a repository with no commits has no HEAD to measure against, and '
        '`git diff HEAD` there is an error rather than an empty answer', () {
      expect(commitDiffArgv(includeUnticked: true, hasCommits: false), [
        'diff',
      ]);
    });
  });

  group('tidyCommitMessage', () {
    test('takes a plain answer as it stands', () {
      expect(
        tidyCommitMessage('Fix the login button on small windows'),
        'Fix the login button on small windows',
      );
    });

    test('drops the fence a model wraps the whole answer in', () {
      expect(
        tidyCommitMessage('```\nFix the login button\n```'),
        'Fix the login button',
      );
      expect(
        tidyCommitMessage('```text\nFix the login button\n```'),
        'Fix the login button',
      );
    });

    test('drops the lead-in a model writes before doing as it was asked', () {
      expect(
        tidyCommitMessage('Commit message: Fix the login button'),
        'Fix the login button',
      );
    });

    test('unquotes the subject and takes off the full stop a commit subject '
        'does not carry', () {
      expect(
        tidyCommitMessage('"Fix the login button."'),
        'Fix the login '
        'button',
      );
    });

    test('keeps a body, separated by the blank line Git expects — and leaves '
        "the body's own punctuation alone", () {
      final message = tidyCommitMessage(
        'Fix the login button\n\nIt overflowed under 400px. The row now wraps.',
      );

      expect(
        message,
        'Fix the login button\n\n'
        'It overflowed under 400px. The row now wraps.',
      );
    });

    test('an answer with nothing in it is nothing, so the caller can say so '
        'instead of committing an empty message', () {
      expect(tidyCommitMessage('   '), isEmpty);
      expect(tidyCommitMessage('```\n\n```'), isEmpty);
    });
  });
}
