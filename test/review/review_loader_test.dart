import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';
import 'package:grid_app/features/review/logic/review_failure.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_loader.dart';

import 'fake_git_runner.dart';
import 'git_fixtures.dart';

void main() {
  late Directory repo;

  setUp(() async {
    // Only the untracked-file count reads the disk; everything else is
    // answered by the fake, and nothing here touches a real repository.
    repo = await Directory.systemTemp.createTemp('review_loader_test');
  });

  tearDown(() async => repo.delete(recursive: true));

  group('uncommitted changes', () {
    test('joins what happened to each file with how much of it changed, so '
        'the list and the counts can never disagree', () async {
      final runner = FakeGitRunner(
        (args) => switch (args) {
          ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
          ['rev-parse', '--verify', ...] => gitSaid('abc123\n'),
          ['rev-parse', ...] => gitRefused('fatal: no upstream', exitCode: 128),
          ['status', ...] => gitSaid(
            z(
              '1 .M N... 100644 100644 100644 422c 422c mod.txt|'
              '1 A. N... 000000 100644 100644 0000 91d5 staged.txt|',
            ),
          ),
          ['diff', '--numstat', ...] => gitSaid(
            z('2\t1\tmod.txt|9\t0\tstaged.txt|'),
          ),
          _ => gitSaid(''),
        },
      );

      final (snapshot, failure) = await ReviewLoader(
        runner,
      ).load(repo.path, const UncommittedChanges());

      expect(failure, isNull);
      expect(snapshot!.branch, 'main');
      expect(snapshot.upstream, isNull);
      expect(snapshot.hasCommits, isTrue);
      expect(snapshot.files.map((f) => f.path), ['mod.txt', 'staged.txt']);
      expect(snapshot.added, 11);
      expect(snapshot.removed, 1);
      expect(snapshot.staged.map((f) => f.path), ['staged.txt']);
    });

    test(
      'counts an untracked file from disk — Git is not tracking it, so '
      '--numstat says nothing and a whole new file would read as empty',
      () async {
        File('${repo.path}/new.txt').writeAsStringSync('one\ntwo\nthree\n');
        final runner = FakeGitRunner(
          (args) => switch (args) {
            ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
            ['status', ...] => gitSaid(z('? new.txt|')),
            _ => gitSaid(''),
          },
        );

        final (snapshot, _) = await ReviewLoader(
          runner,
        ).load(repo.path, const UncommittedChanges());

        expect(snapshot!.files.single.kind, ReviewFileKind.untracked);
        expect(snapshot.files.single.added, 3);
      },
    );

    test('a file that vanished between the status and the count is still '
        'listed, rather than taking the whole screen down', () async {
      final runner = FakeGitRunner(
        (args) => switch (args) {
          ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
          ['status', ...] => gitSaid(z('? gone.txt|')),
          _ => gitSaid(''),
        },
      );

      final (snapshot, failure) = await ReviewLoader(
        runner,
      ).load(repo.path, const UncommittedChanges());

      expect(failure, isNull);
      expect(snapshot!.files.single.path, 'gone.txt');
      expect(snapshot.files.single.added, 0);
    });
  });

  group('branch comparison', () {
    test('asks for the changes since the branch parted from its base, and '
        'reports how far apart the branch and its remote are', () async {
      final runner = FakeGitRunner(
        (args) => switch (args) {
          ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('feat/x\n'),
          ['rev-parse', '--verify', ...] => gitSaid('abc123\n'),
          ['rev-parse', ...] => gitSaid('origin/feat/x\n'),
          ['rev-list', ...] => gitSaid('2\t5\n'),
          ['diff', '--name-status', ...] => gitSaid(z('M|lib/a.dart|')),
          ['diff', '--numstat', ...] => gitSaid(z('4\t2\tlib/a.dart|')),
          _ => gitSaid(''),
        },
      );

      final (snapshot, _) = await ReviewLoader(
        runner,
      ).load(repo.path, const BranchAgainst('origin/main'));

      expect(runner.argsFor('diff'), contains('origin/main...HEAD'));
      expect(snapshot!.upstream, 'origin/feat/x');
      expect(snapshot.behind, 2);
      expect(snapshot.ahead, 5);
      expect(snapshot.files.single.added, 4);
      // Nothing on a branch is still stageable — it is already committed.
      expect(snapshot.files.single.staged, isTrue);
    });

    test('a base that does not exist comes back as Git refusing, with its own '
        'words kept for the log', () async {
      final runner = FakeGitRunner(
        (args) => switch (args) {
          ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
          ['diff', '--name-status', ...] => gitRefused(
            "fatal: ambiguous argument 'nope...HEAD': unknown revision",
            exitCode: 128,
          ),
          _ => gitSaid(''),
        },
      );

      final (snapshot, failure) = await ReviewLoader(
        runner,
      ).load(repo.path, const BranchAgainst('nope'));

      expect(snapshot, isNull);
      expect(failure, isA<ReviewGitRefused>());
      expect((failure! as ReviewGitRefused).raw, contains('unknown revision'));
    });
  });

  test('no Git on this computer is its own answer, not an empty repository — '
      'one offers to install Git, the other says nothing changed', () async {
    final runner = FakeGitRunner((_) => null);

    final (snapshot, failure) = await ReviewLoader(
      runner,
    ).load(repo.path, const UncommittedChanges());

    expect(snapshot, isNull);
    expect(failure, isA<ReviewNoGit>());
  });

  test('a repository whose first commit has not been made still lists its '
      'files, and says there are no commits behind them', () async {
    File('${repo.path}/first.txt').writeAsStringSync('hello\n');
    final runner = FakeGitRunner(
      (args) => switch (args) {
        ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
        ['rev-parse', '--verify', ...] => gitRefused('', exitCode: 1),
        ['status', ...] => gitSaid(z('? first.txt|')),
        ['diff', ...] => gitRefused(
          "fatal: ambiguous argument 'HEAD': unknown revision",
          exitCode: 128,
        ),
        _ => gitSaid(''),
      },
    );

    final (snapshot, failure) = await ReviewLoader(
      runner,
    ).load(repo.path, const UncommittedChanges());

    expect(failure, isNull);
    expect(snapshot!.hasCommits, isFalse);
    expect(snapshot.files.single.added, 1);
  });

  test('a detached HEAD is flagged, because committing there is how work gets '
      'lost', () async {
    final runner = FakeGitRunner(
      (args) => switch (args) {
        ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('HEAD\n'),
        _ => gitSaid(''),
      },
    );

    final (snapshot, _) = await ReviewLoader(
      runner,
    ).load(repo.path, const UncommittedChanges());

    expect(snapshot!.detached, isTrue);
  });

  group('baseRefs', () {
    test(
      'offers remote branches first — a change is measured against what '
      'everyone else has — and never origin/HEAD, which is not a branch',
      () async {
        final runner = FakeGitRunner(
          (args) => switch (args) {
            ['for-each-ref', ...] => gitSaid(
              'refs/heads/main\n'
              'refs/heads/feat/x\n'
              'refs/remotes/origin/HEAD\n'
              'refs/remotes/origin/main\n',
            ),
            _ => gitSaid(''),
          },
        );

        final refs = await ReviewLoader(runner).baseRefs(repo.path);

        expect(refs.map((r) => r.name), ['origin/main', 'main', 'feat/x']);
        // Where a branch lives comes from Git's own ref prefix, not from a
        // guess at its name: `feat/x` has a slash in it and is still local.
        expect(refs.map((r) => r.remote), [true, false, false]);
      },
    );

    test('answers nothing when Git cannot, so the picker degrades instead of '
        'showing a made-up branch', () async {
      final refs = await ReviewLoader(
        FakeGitRunner((_) => null),
      ).baseRefs('/x');

      expect(refs, isEmpty);
    });
  });
}
