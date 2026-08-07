import 'package:grid_app/infrastructure/cli/git_review.dart';

/// A [GitRunner] that answers from a table instead of spawning Git.
///
/// A fake rather than a mock so a test reads as "when the app asks for the
/// status, Git says this" — and so the argv it was actually asked for can be
/// asserted on, which is the half of a CLI integration that silently breaks
/// (§7).
class FakeGitRunner implements GitRunner {
  FakeGitRunner(this._answer);

  /// Answers for one invocation. Returning null is "this computer has no Git",
  /// which is a different failure from Git running and refusing.
  final GitRun? Function(List<String> args) _answer;

  /// Every argv this was asked to run, in order.
  final List<List<String>> calls = [];

  @override
  Future<GitRun?> run(
    String root,
    List<String> args, {
    Duration timeout = kGitCommandTimeout,
  }) async {
    calls.add(args);
    return _answer(args);
  }

  /// Whether any call was `git <first> …` — enough to ask "did it stage?"
  /// without pinning the whole argv.
  bool ran(String subcommand) =>
      calls.any((args) => args.isNotEmpty && args.first == subcommand);

  /// The argv of the first `git <subcommand>` call, or null if it never ran.
  List<String>? argsFor(String subcommand) => calls
      .where((args) => args.isNotEmpty && args.first == subcommand)
      .firstOrNull;
}

/// Git ran and answered.
GitRun gitSaid(String stdout) =>
    GitRun(exitCode: 0, stdout: stdout, stderr: '');

/// Git ran and refused.
GitRun gitRefused(String stderr, {int exitCode = 1}) =>
    GitRun(exitCode: exitCode, stdout: '', stderr: stderr);
