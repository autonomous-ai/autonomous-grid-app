import 'dart:async';
import 'dart:io';

import '../../../infrastructure/cli/git_review.dart';
import 'numstat_parse.dart';
import 'porcelain_parse.dart';
import 'review_argv.dart';
import 'review_base.dart';
import 'review_failure.dart';
import 'review_file.dart';
import 'review_snapshot.dart';

/// Reads a repository into a [ReviewSnapshot].
///
/// Sits between the screen and [GitRunner]: the runner knows how to spawn Git,
/// the argv builders know what to ask, and this knows the order to ask in — and
/// what to do with the answers. Kept out of the controller so it can be tested
/// against a fake runner without Riverpod, and out of `infrastructure` because
/// the shape it returns is the review feature's, not the CLI layer's.
class ReviewLoader {
  const ReviewLoader(this._runner);

  final GitRunner _runner;

  /// A file this size is not something anyone reviews line by line, and reading
  /// it only to count its lines would stall the pass. Anything larger is
  /// reported as binary — honest about not knowing rather than wrong.
  static const int _maxUntrackedBytes = 4 * 1024 * 1024;

  /// Read [root] as it stands, for the comparison [base] asks for. Exactly one
  /// half of the pair is non-null.
  Future<(ReviewSnapshot?, ReviewFailure?)> load(
    String root,
    ReviewBase base,
  ) async {
    final branch = await _runner.run(root, kBranchArgv);
    if (branch == null) return (null, const ReviewNoGit());
    if (!branch.ok) return (null, ReviewGitRefused(branch.failure));

    // Independent of each other and of the file list — asked together so the
    // screen doesn't wait out three round trips in a row.
    final (head, upstream, files) = await (
      _runner.run(root, kHeadExistsArgv),
      _runner.run(root, kUpstreamArgv),
      _files(root, base),
    ).wait;

    final (found, failure) = files;
    if (failure != null) return (null, failure);

    final tracking = (upstream?.ok ?? false) ? upstream!.stdout.trim() : null;
    final (behind, ahead) = await _distance(root, tracking);
    final name = branch.stdout.trim();

    return (
      ReviewSnapshot(
        root: root,
        branch: name,
        base: base,
        files: found ?? const [],
        upstream: tracking,
        ahead: ahead,
        behind: behind,
        hasCommits: head?.ok ?? false,
        detached: name == 'HEAD',
      ),
      null,
    );
  }

  /// The branches the base picker offers, remote ones first: a change is
  /// usually measured against what everyone else has, not against a local copy.
  /// Empty when Git can't answer.
  Future<List<String>> baseRefs(String root) async {
    final result = await _runner.run(root, kRefsArgv);
    if (result == null || !result.ok) return const [];
    final remote = <String>[];
    final local = <String>[];
    for (final line in result.stdout.split('\n')) {
      final ref = line.trim();
      if (ref.startsWith(kRemoteRefPrefix)) {
        final short = ref.substring(kRemoteRefPrefix.length);
        // `origin/HEAD` is a pointer at whichever branch the remote calls its
        // default, not a branch of its own — offering it would list one branch
        // twice under two names.
        if (!short.endsWith('/HEAD')) remote.add(short);
        continue;
      }
      if (ref.startsWith(kLocalRefPrefix)) {
        local.add(ref.substring(kLocalRefPrefix.length));
      }
    }
    return List.unmodifiable([...remote, ...local]);
  }

  /// The file list for [base], with its line counts filled in.
  Future<(List<ReviewFile>?, ReviewFailure?)> _files(
    String root,
    ReviewBase base,
  ) => switch (base) {
    UncommittedChanges() => _uncommitted(root),
    BranchAgainst(:final ref) => _branch(root, ref),
  };

  Future<(List<ReviewFile>?, ReviewFailure?)> _uncommitted(String root) async {
    final status = await _runner.run(root, kStatusArgv);
    if (status == null) return (null, const ReviewNoGit());
    if (!status.ok) return (null, ReviewGitRefused(status.failure));

    final files = parsePorcelainV2(status.stdout);
    // `git diff HEAD` is an error in a repository whose first commit hasn't
    // been made. That isn't worth its own branch: the counts simply don't
    // arrive, and every file there is untracked or staged-new anyway, both of
    // which are counted from disk below.
    final numstat = await _runner.run(
      root,
      numstatArgv(const UncommittedChanges()),
    );
    final counted = numstat != null && numstat.ok
        ? withCounts(files, parseNumstat(numstat.stdout))
        : files;
    return (await _withUntrackedCounts(root, counted), null);
  }

  Future<(List<ReviewFile>?, ReviewFailure?)> _branch(
    String root,
    String ref,
  ) async {
    final (names, numstat) = await (
      _runner.run(root, nameStatusArgv(ref)),
      _runner.run(root, numstatArgv(BranchAgainst(ref))),
    ).wait;
    if (names == null) return (null, const ReviewNoGit());
    if (!names.ok) return (null, ReviewGitRefused(names.failure));

    final files = parseNameStatus(names.stdout);
    if (numstat == null || !numstat.ok) return (files, null);
    return (withCounts(files, parseNumstat(numstat.stdout)), null);
  }

  /// Fills in what an untracked file adds. Git has never been told about these,
  /// so `--numstat` says nothing about them and the answer has to come from
  /// disk — showing a whole new file as "0 lines" would understate the change
  /// the user is about to commit.
  Future<List<ReviewFile>> _withUntrackedCounts(
    String root,
    List<ReviewFile> files,
  ) async {
    final counted = <ReviewFile>[];
    for (final file in files) {
      if (file.kind != ReviewFileKind.untracked) {
        counted.add(file);
        continue;
      }
      final count = await _countOnDisk(root, file);
      counted.add(
        file.copyWith(
          added: count.added,
          removed: count.removed,
          binary: count.binary,
        ),
      );
    }
    return List.unmodifiable(counted);
  }

  Future<DiffCount> _countOnDisk(String root, ReviewFile file) async {
    try {
      final handle = File('$root/${file.path}');
      if (await handle.length() > _maxUntrackedBytes) {
        return (added: 0, removed: 0, binary: true);
      }
      return untrackedCount(await handle.readAsString());
    } on Object {
      // A file that vanished between the status and this read, or bytes that
      // aren't text at all. Either way there is nothing to count, and the row
      // still belongs in the list.
      return (added: 0, removed: 0, binary: true);
    }
  }

  /// How far this branch and its remote are apart, as Git's `behind\tahead`.
  /// Zero for a branch that tracks nothing — there is nothing to be apart from.
  Future<(int behind, int ahead)> _distance(
    String root,
    String? upstream,
  ) async {
    if (upstream == null) return (0, 0);
    final result = await _runner.run(root, aheadBehindArgv(upstream));
    if (result == null || !result.ok) return (0, 0);
    final parts = result.stdout.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return (0, 0);
    return (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
  }
}
