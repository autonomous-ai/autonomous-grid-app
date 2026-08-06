import 'dart:io';

import 'git_probe.dart';
import 'host_environment.dart';

/// What a folder is, as far as Git is concerned.
sealed class GitFolder {
  const GitFolder();
}

/// The folder is inside a Git work tree whose root is [root] — which is the
/// folder itself, or an ancestor of it when the user picked a subdirectory of a
/// repository they already have.
///
/// The distinction matters to the user: an agent running `git` in a
/// subdirectory operates on the *whole* outer repository, not on the folder
/// they chose.
class GitTracked extends GitFolder {
  const GitTracked(this.root);
  final String root;
}

/// No Git anywhere above this folder. A repository can be started here.
class GitUntracked extends GitFolder {
  const GitUntracked();
}

/// Couldn't tell — no Git on this computer, or the folder didn't answer.
///
/// Its own case rather than folding into [GitUntracked], because the two lead
/// somewhere different: one offers to start a repository, the other must
/// promise nothing at all.
class GitFolderUnknown extends GitFolder {
  const GitFolderUnknown();
}

/// Runs Git against a folder on this computer.
///
/// A seam rather than `Process.run('git', …)` inside a feature, for the reason
/// `GridCliService` is one: the executable isn't always `git` on `PATH` — the
/// app unpacks its own under `~/.grid` on a machine that had none — and that
/// copy only works with [HostEnvironment.gitEnvironment] set.
abstract interface class GitRepoService {
  /// Whether [folder] is already under Git.
  Future<GitFolder> inspect(String folder);

  /// Start a repository in [folder]. Null when it worked, else the reason in
  /// the user's terms — the same shape `AgentInstaller.install` returns.
  ///
  /// Only ever called for a [GitUntracked] folder. Running it inside an
  /// existing work tree would nest a second repository under the first, and
  /// every `git log` the agent ran there would answer from the empty inner one
  /// while the user's real history sat a level up.
  Future<String?> init(String folder);
}

class GitRepoServiceImpl implements GitRepoService {
  const GitRepoServiceImpl(this._git);

  /// How to find the Git to run — the app's own cached probe, so this never
  /// spawns a second `git --version` of its own.
  final Future<GitStatus> Function() _git;

  /// `rev-parse` and `init` are millisecond operations on a local disk. The
  /// bound is for the folder on a share that has stopped answering, which must
  /// not hold the dialog open indefinitely.
  static const _timeout = Duration(seconds: 10);

  @override
  Future<GitFolder> inspect(String folder) async {
    if (!Directory(folder).existsSync()) return const GitFolderUnknown();
    final result = await _run(folder, const ['rev-parse', '--show-toplevel']);
    if (result == null) return const GitFolderUnknown();
    // "fatal: not a git repository" is the ordinary answer for a plain folder,
    // not a failure — it is exactly what we asked.
    if (result.exitCode != 0) return const GitUntracked();
    final root = (result.stdout as String).trim();
    return root.isEmpty ? const GitFolderUnknown() : GitTracked(root);
  }

  @override
  Future<String?> init(String folder) async {
    final result = await _run(folder, const ['init']);
    if (result == null) {
      return "There's no Git on this computer to start a repository with.";
    }
    if (result.exitCode == 0) return null;
    final reason = (result.stderr as String).trim();
    return reason.isEmpty ? 'git init exited ${result.exitCode}.' : reason;
  }

  /// `git -C <folder> …`, or null when there is no Git to run or it didn't
  /// answer. Deliberately no `-b`: that flag arrived in Git 2.28 and the app
  /// accepts 2.20, and a plain `init` uses the user's own `init.defaultBranch`
  /// rather than overriding a choice they may have made deliberately.
  Future<ProcessResult?> _run(String folder, List<String> args) async {
    final git = await _git();
    if (git is! GitReady) return null;
    try {
      return await Process.run(git.path, [
        '-C',
        folder,
        ...args,
      ], environment: HostEnvironment.gitEnvironment()).timeout(_timeout);
    } on Object {
      return null;
    }
  }
}
