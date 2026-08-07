import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_base.dart';
import 'package:grid_app/features/review/logic/review_controller.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/infrastructure/cli/git_providers.dart';
import 'package:grid_app/infrastructure/cli/git_repo.dart';

import 'fake_git_runner.dart';
import 'git_fixtures.dart';

/// A [GitRepoService] that answers what the folder is without running Git.
class FakeGitRepoService implements GitRepoService {
  FakeGitRepoService(this.folder);

  final GitFolder folder;

  @override
  Future<GitFolder> inspect(String path) async => folder;

  @override
  Future<String?> init(String path) async => null;
}

/// A container wired to fakes: no Git process, no real repository, no `~/.grid`.
ProviderContainer containerWith({
  required FakeGitRunner runner,
  GitFolder folder = const GitTracked('/repo'),
}) {
  final container = ProviderContainer(
    overrides: [
      gitRunnerProvider.overrideWithValue(runner),
      gitRepoServiceProvider.overrideWithValue(FakeGitRepoService(folder)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The everyday answer: one modified file, on `main`, with no upstream.
FakeGitRunner oneModifiedFile() => FakeGitRunner(
  (args) => switch (args) {
    ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
    ['rev-parse', '--verify', ...] => gitSaid('abc123\n'),
    ['rev-parse', ...] => gitRefused('fatal: no upstream', exitCode: 128),
    ['status', ...] => gitSaid(
      z('1 .M N... 100644 100644 100644 422c 422c lib/a.dart|'),
    ),
    ['diff', '--numstat', ...] => gitSaid(z('3\t1\tlib/a.dart|')),
    _ => gitSaid(''),
  },
);

void main() {
  test('reads the repository the folder sits in, which may be a level above '
      'the folder the user added as a project', () async {
    final container = containerWith(
      runner: oneModifiedFile(),
      folder: const GitTracked('/repo'),
    );

    final state = await container.read(reviewProvider('/repo/lib').future);

    expect(state, isA<ReviewReady>());
    final snapshot = (state as ReviewReady).snapshot;
    expect(snapshot.root, '/repo');
    expect(snapshot.files.single.path, 'lib/a.dart');
    expect(snapshot.added, 3);
  });

  test('a folder that is not in a repository is its own state, so the surface '
      'can offer to start one instead of reporting a failure', () async {
    final container = containerWith(
      runner: oneModifiedFile(),
      folder: const GitUntracked(),
    );

    final state = await container.read(reviewProvider('/plain').future);

    expect(state, isA<ReviewNotARepo>());
  });

  test('a folder Git could not answer for reads as "no Git yet", which is the '
      'one the user can act on', () async {
    final container = containerWith(
      runner: oneModifiedFile(),
      folder: const GitFolderUnknown(),
    );

    expect(
      await container.read(reviewProvider('/unknown').future),
      isA<ReviewNeedsGit>(),
    );
  });

  test('changing the comparison re-reads the repository against the new base '
      '— the picker would be a dead control otherwise', () async {
    final runner = oneModifiedFile();
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    container
        .read(reviewBaseProvider('/repo').notifier)
        .show(const BranchAgainst('origin/main'));
    final state = await container.read(reviewProvider('/repo').future);

    expect((state as ReviewReady).snapshot.base, const BranchAgainst('origin/main'));
    expect(
      runner.calls.any((args) => args.contains('origin/main...HEAD')),
      isTrue,
    );
  });

  test('one repository\'s base does not follow the user into another', () async {
    final container = containerWith(runner: oneModifiedFile());

    container
        .read(reviewBaseProvider('/repo').notifier)
        .show(const BranchAgainst('origin/main'));

    expect(
      container.read(reviewBaseProvider('/other')),
      const UncommittedChanges(),
    );
  });

  test('staging runs git add and re-reads, so the list always says what Git '
      'now holds rather than what the click intended', () async {
    final runner = oneModifiedFile();
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);
    final before = runner.calls.length;

    final error = await container
        .read(reviewProvider('/repo').notifier)
        .stage(
          const ReviewFile(path: 'lib/a.dart', kind: ReviewFileKind.modified),
        );

    expect(error, isNull);
    expect(runner.argsFor('add'), ['add', '--', 'lib/a.dart']);
    // Everything a read needs was asked again after the write.
    expect(runner.calls.length, greaterThan(before + 1));
  });

  test('a refused stage comes back as a sentence to show, not a silent no-op',
      () async {
    final runner = FakeGitRunner(
      (args) => switch (args) {
        ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
        ['status', ...] => gitSaid(
          z('1 .M N... 100644 100644 100644 422c 422c lib/a.dart|'),
        ),
        ['add', ...] => gitRefused(
          'fatal: pathspec did not match any files',
          exitCode: 128,
        ),
        _ => gitSaid(''),
      },
    );
    final container = containerWith(runner: runner);
    await container.read(reviewProvider('/repo').future);

    final error = await container
        .read(reviewProvider('/repo').notifier)
        .stage(
          const ReviewFile(path: 'lib/a.dart', kind: ReviewFileKind.modified),
        );

    expect(error, isNotNull);
    // Git's own words, tidied of the `fatal:` prefix — not a sentence the app
    // invented about a failure it doesn't recognise.
    expect(error, 'Pathspec did not match any files');
  });
}
