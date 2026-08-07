import 'review_file.dart';
import 'review_scope.dart';

/// Every `git` invocation the Review screen makes, built here and nowhere else.
///
/// Pure functions rather than argv assembled at the call site, because a wrong
/// flag fails exactly like a repository with nothing in it (§7): `git diff`
/// takes `--cached`, `git status` doesn't; `git show` needs `--format=` or it
/// prints its own header into the diff; `--no-index` needs two paths and the
/// null device spelled the platform's way. Each of these is covered by a test
/// that names the shape it protects.

/// Which files changed, and on which side — index, working tree, or neither.
const List<String> kStatusArgv = [
  'status',
  '--porcelain=v2',
  '-z',
  '--untracked-files=all',
];

/// The branch name, or `HEAD` when the repository is on a detached commit.
const List<String> kBranchArgv = ['rev-parse', '--abbrev-ref', 'HEAD'];

/// Whether `HEAD` resolves at all — it doesn't in a repository whose first
/// commit hasn't been made, where `git diff HEAD` is an error rather than an
/// empty answer.
const List<String> kHeadExistsArgv = ['rev-parse', '--verify', '-q', 'HEAD'];

/// The remote branch this one tracks. Fails (exit 128) when it tracks none,
/// which is how "never pushed" is told from "up to date".
const List<String> kUpstreamArgv = [
  'rev-parse',
  '--abbrev-ref',
  '--symbolic-full-name',
  '@{upstream}',
];

/// Every branch this repository knows, local and remote — what the base picker
/// offers.
///
/// Asks for the *full* ref name rather than the short one: shortened,
/// `origin/main` and a local branch called `feat/x` are both "a name with a
/// slash in it", and there is no way left to tell a remote branch from a local
/// one. The `refs/remotes/` prefix is the only reliable answer.
const List<String> kRefsArgv = [
  'for-each-ref',
  '--format=%(refname)',
  'refs/heads',
  'refs/remotes',
];

/// Where Git keeps remote branches; what [kRefsArgv]'s answer is sorted by.
const String kRemoteRefPrefix = 'refs/remotes/';

/// Where it keeps local ones.
const String kLocalRefPrefix = 'refs/heads/';

/// Field and record separators for `git log`.
///
/// Unit and record separator, not `|` or a newline: a commit subject may
/// contain any printable character, and every printable delimiter has already
/// been used in somebody's commit message.
const String kLogFieldSeparator = '\u001f';
const String kLogRecordSeparator = '\u001e';

/// The last [limit] commits on this branch, for the Committed menu.
List<String> recentCommitsArgv({int limit = 20}) => [
  'log',
  '-n',
  '$limit',
  '--format=%H$kLogFieldSeparator%s$kLogFieldSeparator%an'
      '$kLogFieldSeparator%ar$kLogRecordSeparator',
];

/// How many commits [upstream] has that we don't, and the other way round.
/// Answers as `<behind>\t<ahead>` — left is the upstream side.
List<String> aheadBehindArgv(String upstream) => [
  'rev-list',
  '--left-right',
  '--count',
  '$upstream...HEAD',
];

/// The changed-line counts for a whole scope.
List<String> numstatArgv(ReviewScope scope) => switch (scope) {
  CommittedChange(:final commit) => [
    'show',
    '--numstat',
    '-z',
    '-M',
    // Without this, `git show` prints its own commit header above the diff and
    // the first "file" parsed out of it is the subject line.
    '--format=',
    commit.sha,
  ],
  _ => ['diff', '--numstat', '-z', '-M', ...?_range(scope)],
};

/// What each file's change *is*, where `status` can't answer: a branch
/// comparison and a commit have no index and no working tree, only what the
/// commits did.
List<String> nameStatusArgv(ReviewScope scope) => switch (scope) {
  CommittedChange(:final commit) => [
    'show',
    '--name-status',
    '-M',
    '-z',
    '--format=',
    commit.sha,
  ],
  _ => ['diff', '--name-status', '-M', '-z', ...?_range(scope)],
};

/// One file's diff.
///
/// A rename is passed both of its paths: given only the new one, Git has
/// nothing to pair it with and reports a file that appeared from nowhere —
/// every line "added", which is the opposite of what a rename is.
///
/// [ignoreWhitespace] is Git's own `-w`, not a filter applied after the fact:
/// asking Git to ignore whitespace drops the *lines* that differ by nothing
/// else, which is the point — a re-indented file otherwise reads as rewritten
/// from top to bottom.
List<String> fileDiffArgv({
  required ReviewScope scope,
  required ReviewFile file,
  required String nullDevice,
  bool ignoreWhitespace = false,
}) {
  final space = [if (ignoreWhitespace) '-w'];
  // An untracked file isn't in the index or in HEAD, so `git diff` has nothing
  // to compare and prints nothing at all. `--no-index` diffs two paths on disk
  // directly; against the null device, every line reads as added — which is
  // what an entirely new file is.
  if (file.kind == ReviewFileKind.untracked) {
    return ['diff', '--no-index', ...space, '--', nullDevice, file.path];
  }
  final paths = ['--', ?file.oldPath, file.path];
  return switch (scope) {
    CommittedChange(:final commit) => [
      'show',
      '-M',
      ...space,
      '--format=',
      commit.sha,
      ...paths,
    ],
    _ => ['diff', '-M', ...space, ...?_range(scope), ...paths],
  };
}

/// Put a file's change in the index, so the next commit carries it. Works for
/// an untracked file too — that is how it gets tracked in the first place.
///
/// A rename passes both of its paths: staging only the new one would commit the
/// arrival of the file without the departure, leaving a copy behind.
List<String> stageArgv(List<String> paths) => ['add', '--', ...paths];

/// Take it back out again.
///
/// `git restore --staged` is the modern spelling and is *not* used: it arrived
/// in Git 2.23 and this app supports 2.20. In a repository with no commits yet
/// there is no `HEAD` to reset against, so the file is simply dropped from the
/// index.
List<String> unstageArgv(List<String> paths, {required bool hasCommits}) =>
    hasCommits
    ? ['reset', '-q', 'HEAD', '--', ...paths]
    : ['rm', '--cached', '-q', '--', ...paths];

/// Ticking every file the list is showing, as commands short enough to run.
///
/// Their paths rather than `git add -A`, which is what this used to be: under a
/// narrowed scope — the assistant's last turn — "everything" means the files on
/// screen, and `-A` would quietly put work the user never saw into their next
/// commit. Staging a path covers a deletion too, so nothing is lost by naming
/// them.
///
/// Batched because a command line has a length limit and Windows' is 32 KB: a
/// repository with a thousand changed files would otherwise fail on the one
/// command that was meant to save the user a thousand clicks.
List<List<String>> stageBatches(List<ReviewFile> files, {int perBatch = 50}) =>
    [
      for (var start = 0; start < files.length; start += perBatch)
        stageArgv([
          for (final file in files.skip(start).take(perBatch)) ...[
            ?file.oldPath,
            file.path,
          ],
        ]),
    ];

/// The change a commit would carry, as a patch for a model to read.
///
/// [includeUnticked] follows the panel's toggle, because the message has to
/// describe what will actually be committed — asking a model to summarise the
/// index while the commit sweeps in three more files produces a message that is
/// wrong in the one way nobody re-reads.
///
/// In a repository with no commits yet there is no `HEAD` to measure against,
/// and `git diff HEAD` is an error rather than an empty answer; the working
/// tree against the index is the closest true thing.
List<String> commitDiffArgv({
  required bool includeUnticked,
  required bool hasCommits,
}) {
  if (!includeUnticked) return const ['diff', '--cached'];
  return hasCommits ? const ['diff', 'HEAD'] : const ['diff'];
}

/// Commit what's staged. Deliberately no `-a`: staging is the user's decision,
/// made file by file on this screen, and `-a` would quietly widen a commit
/// beyond what the list showed them.
List<String> commitArgv(String message) => ['commit', '-m', message];

/// Send the branch to its remote. A branch that tracks nothing yet is given
/// `origin` and its own name — the same thing Git tells you to type.
List<String> pushArgv({required String branch, required bool setUpstream}) =>
    setUpstream ? ['push', '--set-upstream', 'origin', branch] : const ['push'];

/// What a `git diff` in this scope compares, as the arguments that go after the
/// flags: `HEAD`, `--cached`, a three-dot range — or nothing at all, which is
/// how Git spells "the working tree against the index".
///
/// Null for a commit, which is read with `git show` rather than `git diff`.
List<String>? _range(ReviewScope scope) => switch (scope) {
  // The assistant's edits live in the working tree and the index alike, so its
  // scope is measured exactly as "uncommitted" is; the narrowing to the files
  // it touched happens on the file list, not in the range.
  LastTurnChanges() || UncommittedChanges() => const ['HEAD'],
  UnstagedChanges() => const [],
  StagedChanges() => const ['--cached'],
  BranchAgainst(:final ref) => ['$ref...HEAD'],
  CommittedChange() => null,
};
