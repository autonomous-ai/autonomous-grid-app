import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_argv.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';
import 'package:grid_app/features/review/logic/review_file.dart';

/// A wrong flag fails exactly like a repository with nothing in it, so each of
/// these names the shape it protects rather than restating the code.
void main() {
  group('what a diff is measured against', () {
    test('uncommitted work is measured against HEAD, so a change that is only '
        'staged is still in the list', () {
      expect(numstatArgv(const UncommittedChanges()).last, 'HEAD');
    });

    test('a branch is measured from where it parted from the base (three '
        'dots) — two dots would count the base\'s own new commits as this '
        "branch's removals", () {
      expect(
        numstatArgv(const BranchAgainst('origin/main')).last,
        'origin/main...HEAD',
      );
      expect(
        nameStatusArgv(const BranchAgainst('origin/main')).last,
        'origin/main...HEAD',
      );
    });
  });

  group('fileDiffArgv', () {
    test('diffs an untracked file against the null device, because Git has '
        'nothing to compare it with and would print nothing at all', () {
      final args = fileDiffArgv(
        scope: const UncommittedChanges(),
        file: const ReviewFile(path: 'new.txt', kind: ReviewFileKind.untracked),
        nullDevice: '/dev/null',
      );

      expect(args, ['diff', '--no-index', '--', '/dev/null', 'new.txt']);
    });

    test('passes both paths of a rename, or Git reports a file that appeared '
        'from nowhere with every line added', () {
      final args = fileDiffArgv(
        scope: const UncommittedChanges(),
        file: const ReviewFile(
          path: 'new/name.dart',
          oldPath: 'old/name.dart',
          kind: ReviewFileKind.renamed,
        ),
        nullDevice: '/dev/null',
      );

      expect(args, [
        'diff',
        '-M',
        'HEAD',
        '--',
        'old/name.dart',
        'new/name.dart',
      ]);
    });

    test('an ordinary file is diffed by its path alone', () {
      final args = fileDiffArgv(
        scope: const BranchAgainst('main'),
        file: const ReviewFile(path: 'a.dart', kind: ReviewFileKind.modified),
        nullDevice: '/dev/null',
      );

      expect(args, ['diff', '-M', 'main...HEAD', '--', 'a.dart']);
    });
  });

  group('staging', () {
    test('stages both halves of a rename, or the commit records the arrival '
        'without the departure and leaves a copy behind', () {
      expect(stageArgv(['old.txt', 'new.txt']), [
        'add',
        '--',
        'old.txt',
        'new.txt',
      ]);
    });

    test('unstages with reset, not restore: restore arrived in Git 2.23 and '
        'this app supports 2.20', () {
      expect(unstageArgv(['a.txt'], hasCommits: true), [
        'reset',
        '-q',
        'HEAD',
        '--',
        'a.txt',
      ]);
    });

    test('drops a file from the index instead of resetting when the '
        "repository has no commits — there is no HEAD to reset against", () {
      expect(unstageArgv(['a.txt'], hasCommits: false), [
        'rm',
        '--cached',
        '-q',
        '--',
        'a.txt',
      ]);
    });

    test('commits only what is staged — never -a, which would widen the '
        'commit past what the list showed', () {
      expect(commitArgv('Fix the thing'), ['commit', '-m', 'Fix the thing']);
    });
  });

  group('pushArgv', () {
    test('tells Git where a branch belongs the first time it is pushed', () {
      expect(pushArgv(branch: 'feat/x', setUpstream: true), [
        'push',
        '--set-upstream',
        'origin',
        'feat/x',
      ]);
    });

    test('a branch that already tracks a remote is pushed plainly, so Git '
        'uses the remote the user configured', () {
      expect(pushArgv(branch: 'main', setUpstream: false), ['push']);
    });
  });
}
