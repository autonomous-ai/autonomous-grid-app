import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/commit_controller.dart';
import 'package:grid_app/features/review/logic/review_controller.dart';
import 'package:grid_app/infrastructure/cli/git_review.dart';

import 'fake_git_runner.dart';
import 'git_fixtures.dart';
import 'review_controller_test.dart' show containerWith;

/// A repository with one staged file, on `main`, tracking `origin/main`.
FakeGitRunner _staged({GitRun? Function(List<String> args)? override}) =>
    FakeGitRunner(
      (args) =>
          override?.call(args) ??
          switch (args) {
            ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
            ['rev-parse', '--verify', ...] => gitSaid('abc123\n'),
            ['rev-parse', ...] => gitSaid('origin/main\n'),
            ['status', ...] => gitSaid(
              z('1 M. N... 100644 100644 100644 422c 422c lib/a.dart|'),
            ),
            _ => gitSaid(''),
          },
    );

void main() {
  test('commits and pushes, and says which branch went where', () async {
    final runner = _staged();
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    await container
        .read(commitProvider('/repo').notifier)
        .run(message: 'Fix the thing', push: true);

    expect(runner.argsFor('commit'), ['commit', '-m', 'Fix the thing']);
    // The branch already tracks a remote, so Git is left to use it.
    expect(runner.argsFor('push'), ['push']);
    final state = container.read(commitProvider('/repo'));
    expect(state, isA<CommitDone>());
    expect((state as CommitDone).pushed, isTrue);
  });

  test('tells Git where a never-pushed branch belongs, instead of failing with '
      'the instructions Git would have printed', () async {
    final runner = _staged(
      override: (args) => switch (args) {
        ['rev-parse', '--abbrev-ref', '--symbolic-full-name', ...] =>
          gitRefused('fatal: no upstream configured', exitCode: 128),
        _ => null,
      },
    );
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    await container
        .read(commitProvider('/repo').notifier)
        .run(message: 'First', push: true);

    expect(runner.argsFor('push'), [
      'push',
      '--set-upstream',
      'origin',
      'main',
    ]);
  });

  test('a push that fails after the commit landed says the commit was made — '
      'or the user commits the same work twice', () async {
    final runner = _staged(
      override: (args) => switch (args) {
        ['push', ...] => gitRefused(
          "fatal: could not read Username for 'https://github.com': terminal "
          'prompts disabled',
          exitCode: 128,
        ),
        _ => null,
      },
    );
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    await container
        .read(commitProvider('/repo').notifier)
        .run(message: 'Fix the thing', push: true);

    final state = container.read(commitProvider('/repo'));
    expect(state, isA<CommitFailed>());
    expect((state as CommitFailed).committed, isTrue);
    expect(state.message, contains('sign in'));
  });

  test('a commit Git refuses never claims to have happened', () async {
    final runner = _staged(
      override: (args) => switch (args) {
        ['commit', ...] => gitRefused(
          'On branch main\nnothing to commit, working tree clean',
          exitCode: 1,
        ),
        _ => null,
      },
    );
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    await container
        .read(commitProvider('/repo').notifier)
        .run(message: 'Nothing', push: true);

    final state = container.read(commitProvider('/repo'));
    expect(state, isA<CommitFailed>());
    expect((state as CommitFailed).committed, isFalse);
    expect(runner.ran('push'), isFalse);
  });

  test('an empty message is refused here rather than by Git, so the user is '
      'told what to do instead of what failed', () async {
    final runner = _staged();
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    await container
        .read(commitProvider('/repo').notifier)
        .run(message: '   ', push: false);

    expect(runner.ran('commit'), isFalse);
    expect(container.read(commitProvider('/repo')), isA<CommitFailed>());
  });

  test(
    'committing without pushing leaves the work local and says so',
    () async {
      final runner = _staged();
      final container = containerWith(runner: runner);
      await container.read(reviewProvider('/repo').future);

      await container
          .read(commitProvider('/repo').notifier)
          .run(message: 'Local only', push: false);

      expect(runner.ran('push'), isFalse);
      final state = container.read(commitProvider('/repo'));
      expect((state as CommitDone).pushed, isFalse);
    },
  );
}
