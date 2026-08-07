import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/commit_log_parse.dart';
import 'package:grid_app/features/review/logic/review_argv.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_loader.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';

import 'fake_git_runner.dart';
import 'git_fixtures.dart';

/// One file staged, one only in the working tree, one untracked — the mix that
/// tells the four working-tree scopes apart.
const _mixed =
    '1 M. N... 100644 100644 100644 aaa aaa staged.dart|'
    '1 .M N... 100644 100644 100644 bbb bbb worktree.dart|'
    '1 MM N... 100644 100644 100644 ccc ccc both.dart|'
    '? new.dart|';

FakeGitRunner _repo() => FakeGitRunner(
  (args) => switch (args) {
    ['rev-parse', '--abbrev-ref', 'HEAD'] => gitSaid('main\n'),
    ['rev-parse', '--verify', ...] => gitSaid('abc123\n'),
    ['rev-parse', ...] => gitRefused('fatal: no upstream', exitCode: 128),
    ['status', ...] => gitSaid(z(_mixed)),
    _ => gitSaid(''),
  },
);

void main() {
  late Directory repo;

  setUp(() async {
    repo = await Directory.systemTemp.createTemp('review_scopes_test');
  });

  tearDown(() async => repo.delete(recursive: true));

  group('which files each scope shows', () {
    test('uncommitted is everything, because that is what would be lost if '
        'the folder were thrown away', () async {
      final (snapshot, _) = await ReviewLoader(
        _repo(),
      ).load(repo.path, const UncommittedChanges());

      expect(snapshot!.files.map((f) => f.path), [
        'both.dart',
        'new.dart',
        'staged.dart',
        'worktree.dart',
      ]);
    });

    test('staged is what the next commit would carry — and never an untracked '
        'file, which is in no index at all', () async {
      final (snapshot, _) = await ReviewLoader(
        _repo(),
      ).load(repo.path, const StagedChanges());

      expect(snapshot!.files.map((f) => f.path), ['both.dart', 'staged.dart']);
    });

    test('unstaged is what a commit would leave behind, untracked files '
        'included — they are the most unstaged thing there is', () async {
      final (snapshot, _) = await ReviewLoader(
        _repo(),
      ).load(repo.path, const UnstagedChanges());

      expect(snapshot!.files.map((f) => f.path), [
        'both.dart',
        'new.dart',
        'worktree.dart',
      ]);
    });

    test('last turn is only what the assistant touched, matched on the '
        'absolute path Git never reports', () async {
      final (snapshot, _) = await ReviewLoader(_repo()).load(
        repo.path,
        const LastTurnChanges(),
        lastTurnPaths: {'${repo.path}/worktree.dart'},
      );

      expect(snapshot!.files.map((f) => f.path), ['worktree.dart']);
    });

    test('a turn that touched nothing here shows nothing, rather than falling '
        'back to every change in the folder', () async {
      final (snapshot, _) = await ReviewLoader(
        _repo(),
      ).load(repo.path, const LastTurnChanges());

      expect(snapshot!.files, isEmpty);
    });
  });

  group('which commands each scope runs', () {
    test('staged asks Git for the index, unstaged for the working tree — the '
        'two differ by one flag, and mixing them shows the wrong half', () {
      expect(numstatArgv(const StagedChanges()), contains('--cached'));
      expect(numstatArgv(const UnstagedChanges()), isNot(contains('--cached')));
      expect(numstatArgv(const UnstagedChanges()), isNot(contains('HEAD')));
      expect(numstatArgv(const UncommittedChanges()), contains('HEAD'));
    });

    test('a commit is read with `git show --format=`, because without that '
        'flag Git prints its own header and the subject parses as a file', () {
      const commit = CommitRef(
        sha: 'abc123',
        subject: 'Fix',
        author: 'Dev',
        when: 'now',
      );
      final args = numstatArgv(const CommittedChange(commit));

      expect(args.first, 'show');
      expect(args, contains('--format='));
      expect(args.last, 'abc123');
    });

    test("a commit's file diff is `git show`, not `git diff`", () {
      const commit = CommitRef(
        sha: 'abc123',
        subject: 'Fix',
        author: 'Dev',
        when: 'now',
      );
      final args = fileDiffArgv(
        scope: const CommittedChange(commit),
        file: const ReviewFile(path: 'a.dart', kind: ReviewFileKind.modified),
        nullDevice: '/dev/null',
      );

      expect(args, ['show', '-M', '--format=', 'abc123', '--', 'a.dart']);
    });

    test('the last turn is measured exactly as uncommitted work is — the '
        'narrowing is a file list, not a different range', () {
      expect(
        numstatArgv(const LastTurnChanges()),
        numstatArgv(const UncommittedChanges()),
      );
    });
  });

  group('parseCommitLog', () {
    test('reads the commits the menu lists, keeping a subject that contains '
        'the characters a printable delimiter would have split on', () {
      final commits = parseCommitLog(
        'abc123${kLogFieldSeparator}feat: add | pipes, and — dashes'
        '${kLogFieldSeparator}Dev jacob${kLogFieldSeparator}2 hours ago'
        '$kLogRecordSeparator'
        '\ndef456${kLogFieldSeparator}Second${kLogFieldSeparator}Someone'
        '${kLogFieldSeparator}3 days ago$kLogRecordSeparator\n',
      );

      expect(commits.length, 2);
      expect(commits.first.subject, 'feat: add | pipes, and — dashes');
      expect(commits.first.author, 'Dev jacob');
      expect(commits.first.when, '2 hours ago');
      expect(commits.first.shortSha, 'abc123');
      expect(commits.last.sha, 'def456');
    });

    test('skips a record it cannot read rather than losing the whole menu', () {
      final commits = parseCommitLog(
        'broken$kLogRecordSeparator'
        'abc123${kLogFieldSeparator}Fine${kLogFieldSeparator}Dev'
        '${kLogFieldSeparator}now$kLogRecordSeparator',
      );

      expect(commits.single.subject, 'Fine');
    });

    test('a repository with no commits yet lists none', () {
      expect(parseCommitLog(''), isEmpty);
    });
  });
}
