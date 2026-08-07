import 'review_base.dart';
import 'review_file.dart';

/// Every `git` invocation the Review screen makes, built here and nowhere else.
///
/// Pure functions rather than argv assembled at the call site, because a wrong
/// flag fails exactly like a repository with nothing in it (§7): `git diff`
/// takes `--cached`, `git status` doesn't; `--no-index` needs two paths and
/// ignores `-C`-relative ones on Windows unless the null device is spelled the
/// platform's way. Each of these is covered by a test that names the shape it
/// protects.

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

/// How many commits [upstream] has that we don't, and the other way round.
/// Answers as `<behind>\t<ahead>` — left is the upstream side.
List<String> aheadBehindArgv(String upstream) => [
  'rev-list',
  '--left-right',
  '--count',
  '$upstream...HEAD',
];

/// The changed-line counts for the whole change set.
List<String> numstatArgv(ReviewBase base) => [
  'diff',
  '--numstat',
  '-z',
  '-M',
  _range(base),
];

/// What each file's change *is*, for a branch comparison — the working tree
/// isn't involved, so `status` can't answer this one.
List<String> nameStatusArgv(String ref) => [
  'diff',
  '--name-status',
  '-M',
  '-z',
  _threeDot(ref),
];

/// One file's diff.
///
/// A rename is passed both of its paths: given only the new one, Git has
/// nothing to pair it with and reports a file that appeared from nowhere —
/// every line "added", which is the opposite of what a rename is.
List<String> fileDiffArgv({
  required ReviewBase base,
  required ReviewFile file,
  required String nullDevice,
}) {
  // An untracked file isn't in the index or in HEAD, so `git diff` has nothing
  // to compare and prints nothing at all. `--no-index` diffs two paths on disk
  // directly; against the null device, every line reads as added — which is
  // what an entirely new file is.
  if (file.kind == ReviewFileKind.untracked) {
    return ['diff', '--no-index', '--', nullDevice, file.path];
  }
  return ['diff', '-M', _range(base), '--', ?file.oldPath, file.path];
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

/// Stage everything that changed, deletions included — what "Select all" does.
const List<String> kStageAllArgv = ['add', '-A'];

/// Commit what's staged. Deliberately no `-a`: staging is the user's decision,
/// made file by file on this screen, and `-a` would quietly widen a commit
/// beyond what the list showed them.
List<String> commitArgv(String message) => ['commit', '-m', message];

/// Send the branch to its remote. A branch that tracks nothing yet is given
/// `origin` and its own name — the same thing Git tells you to type.
List<String> pushArgv({required String branch, required bool setUpstream}) =>
    setUpstream ? ['push', '--set-upstream', 'origin', branch] : const ['push'];

/// What a diff command compares against: `HEAD` for the working tree, or the
/// three-dot form for a branch.
String _range(ReviewBase base) => switch (base) {
  UncommittedChanges() => 'HEAD',
  BranchAgainst(:final ref) => _threeDot(ref),
};

/// `ref...HEAD` — from where the branch parted from [ref], not from [ref] as it
/// stands now. Without the third dot, commits that landed on `main` after this
/// branch started would read as changes this branch *removed*.
String _threeDot(String ref) => '$ref...HEAD';
