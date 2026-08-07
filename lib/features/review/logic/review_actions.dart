import 'dart:io';

import '../../../infrastructure/cli/git_review.dart';
import 'review_argv.dart';
import 'review_scope.dart';
import 'review_failure.dart';
import 'review_file.dart';

/// The commands that *change* something — staging, committing, pushing — and
/// the one read that isn't part of a snapshot: a single file's diff.
///
/// Separate from [ReviewLoader] because the two are read and write: everything
/// here touches the user's repository, so each method is called from exactly
/// one place, after an explicit click.
class ReviewActions {
  const ReviewActions(this._runner);

  final GitRunner _runner;

  /// One file's diff, as Git prints it. Null when it couldn't be read — the
  /// pane says so rather than drawing an empty file.
  Future<String?> patch({
    required String root,
    required ReviewScope scope,
    required ReviewFile file,
  }) async {
    final result = await _runner.run(
      root,
      fileDiffArgv(scope: scope, file: file, nullDevice: nullDevice),
    );
    if (result == null) return null;
    // `git diff --no-index` reports "these differ" as exit code 1, which is the
    // *normal* answer for every untracked file. Treating it as failure would
    // leave a new file's diff permanently blank.
    if (!result.ok && result.stdout.trim().isEmpty) return null;
    return result.stdout;
  }

  /// Include [file] in the next commit.
  Future<ReviewFailure?> stage(String root, ReviewFile file) =>
      _write(root, stageArgv([?file.oldPath, file.path]));

  /// Leave [file] out of it again.
  Future<ReviewFailure?> unstage(
    String root,
    ReviewFile file, {
    required bool hasCommits,
  }) => _write(
    root,
    unstageArgv([?file.oldPath, file.path], hasCommits: hasCommits),
  );

  /// Include everything that changed.
  Future<ReviewFailure?> stageAll(String root) => _write(root, kStageAllArgv);

  /// Record what's staged as a commit.
  Future<ReviewFailure?> commit(String root, String message) =>
      _write(root, commitArgv(message));

  /// Send [branch] to its remote, telling Git where it belongs when it has no
  /// upstream yet.
  Future<ReviewFailure?> push(
    String root, {
    required String branch,
    required bool setUpstream,
  }) => _write(
    root,
    pushArgv(branch: branch, setUpstream: setUpstream),
    timeout: kGitPushTimeout,
  );

  Future<ReviewFailure?> _write(
    String root,
    List<String> args, {
    Duration timeout = kGitCommandTimeout,
  }) async {
    final result = await _runner.run(root, args, timeout: timeout);
    if (result == null) return const ReviewNoGit();
    if (!result.ok) return ReviewGitRefused(result.failure);
    return null;
  }
}

/// The empty file to diff a brand-new file against. Windows spells it `NUL`;
/// everywhere else it's `/dev/null`. Getting this wrong doesn't fail loudly —
/// Git reports "no such path", and every untracked file's diff comes back
/// blank.
String get nullDevice => Platform.isWindows ? 'NUL' : '/dev/null';
