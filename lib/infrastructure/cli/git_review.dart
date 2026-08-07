import 'dart:convert';
import 'dart:io';

import 'git_probe.dart';
import 'host_environment.dart';

/// What one `git` invocation answered.
///
/// Both streams are kept: [stdout] is what the caller parses, [stderr] is what
/// gets logged and turned into a sentence when the command failed — a humanised
/// message that replaced the raw text would leave nothing to diagnose with (§6).
class GitRun {
  const GitRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// What to show when this run failed: Git's own words, or the exit code when
  /// it said nothing at all.
  String get failure {
    final reason = stderr.trim().isEmpty ? stdout.trim() : stderr.trim();
    return reason.isEmpty ? 'git exited $exitCode.' : reason;
  }
}

/// Runs arbitrary `git` argv against a repository on this computer.
///
/// A seam for the same reason [GitRepoService] is one — the executable isn't
/// always `git` on `PATH`, and the copy the app unpacks only works with
/// [HostEnvironment.gitEnvironment] set — but deliberately *thin*: which
/// arguments to run is a decision the review feature makes in pure, tested
/// functions (`review_argv.dart`), not something buried in here.
abstract interface class GitRunner {
  /// Run `git -C <root> <args>`. Null when this computer has no Git to run, or
  /// the process never answered — the caller distinguishes "couldn't ask" from
  /// "asked and Git said no".
  Future<GitRun?> run(
    String root,
    List<String> args, {
    Duration timeout = kGitCommandTimeout,
  });
}

/// How long an ordinary read (`status`, `diff`, `rev-parse`) may take. Local
/// disk answers in milliseconds; the bound is for the repository on a share
/// that has stopped answering, which must not freeze the screen.
const Duration kGitCommandTimeout = Duration(seconds: 20);

/// How long `push` may take — it crosses the network and a large first push is
/// genuinely slow, so it gets its own, much longer bound.
const Duration kGitPushTimeout = Duration(minutes: 3);

class GitRunnerImpl implements GitRunner {
  const GitRunnerImpl(this._git);

  /// How to find the Git to run — the app's own cached probe, so this never
  /// spawns a second `git --version` of its own.
  final Future<GitStatus> Function() _git;

  @override
  Future<GitRun?> run(
    String root,
    List<String> args, {
    Duration timeout = kGitCommandTimeout,
  }) async {
    final git = await _git();
    if (git is! GitReady) return null;
    try {
      final result = await Process.run(
        git.path,
        ['-C', root, ...args],
        environment: reviewGitEnvironment(),
        // Git speaks UTF-8 for paths and file contents; the system codepage
        // would mangle every accented filename and every non-ASCII line of a
        // diff. Malformed bytes become U+FFFD rather than throwing, so one
        // stray byte in a binary-ish file can't take the whole screen down.
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(timeout);
      return GitRun(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on Object {
      return null;
    }
  }
}

/// The environment every review command runs with: whatever the app's own Git
/// needs, plus the switches that stop Git asking a human for a password.
///
/// **This is what keeps `push` from hanging forever.** A Flutter app has no
/// terminal, so a `git push` that decides to prompt for credentials would sit
/// there unanswered until the timeout — with no way for the user to type
/// anything. Failing fast is what lets the screen say "sign in from Terminal"
/// instead of spinning.
/// The machine's credential helper still runs — a user whose keychain already
/// holds the token pushes without being asked anything, which is the common
/// case. Only the *interactive* fallbacks are shut off.
Map<String, String> reviewGitEnvironment() => {
  ...HostEnvironment.gitEnvironment(),
  'GIT_TERMINAL_PROMPT': '0',
  // Without this, an SSH remote on a host the machine hasn't seen before stops
  // to ask "are you sure you want to continue connecting?" — the same hang in a
  // different coat. Overriding a `GIT_SSH_COMMAND` the user set themselves is
  // deliberate: a GUI app's environment rarely carries one, and a prompt we
  // can't answer is worse than an option they didn't choose.
  'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
};
