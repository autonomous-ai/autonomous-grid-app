import 'parsers/download_progress.dart';

/// Result of a one-shot lifecycle command (nguồn 2 in the contract).
/// Success is `exitCode == 0`; on failure the CLI writes to stderr
/// (cli.py:1076). We never parse stdout on success — read `~/.grid` instead.
class CliResult {
  const CliResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  String get errorMessage {
    final err = stderr.trim();
    return err.isNotEmpty ? err : stdout.trim();
  }

  /// The command failed because the saved Grid session is no longer valid — the
  /// user must re-run `grid login`. The control plane has no structured error
  /// code, so we string-match the CLI's own sign-in-required messages, kept in
  /// one place so detection stays consistent:
  /// - `grid sync` on a dead session: "Your grid session has expired. Run
  ///   `grid login` to sign in again." (cli/auth.py)
  /// - the `require_session` gate every cloud command shares: "You're not signed
  ///   in. Run `grid login` to sign in." (cloud/credentials.py)
  /// - `grid chat`/media on a 401: "Your access token has expired…"
  /// - the legacy single-mode wording, kept for older binaries.
  bool get sessionExpired {
    if (ok) return false;
    final msg = errorMessage.toLowerCase();
    return msg.contains('session expired or invalid') ||
        msg.contains('session has expired') ||
        msg.contains('access token has expired') ||
        msg.contains("you're not signed in");
  }
}

/// One line emitted by a long-running command (provider/install logs, §3.5).
class CliLine {
  const CliLine({required this.isStderr, required this.text});

  final bool isStderr;
  final String text;
}

/// A handle to a running, app-owned `grid` process. Used where we need both the
/// live output (e.g. the device-login URL mid-stream) and the final exit code,
/// and where we may need to kill it (e.g. `grid join` / an install on window
/// close — loại 2 in the contract's process model).
class GridProcess {
  const GridProcess({
    required this.lines,
    required this.exitCode,
    required this.kill,
  });

  /// Merged stdout/stderr lines, in arrival order.
  final Stream<CliLine> lines;

  /// Completes with the process exit code (0 = success).
  final Future<int> exitCode;

  /// Sends SIGTERM (best effort) to the process.
  final void Function() kill;
}

/// The seam between the app and the `grid` CLI. The whole app depends on this
/// interface so UI can be built and tested against [FakeGridCliService] without
/// a real CLI, network, or model download.
abstract interface class GridCliService {
  /// Run a lifecycle command to completion and capture its output.
  ///
  /// [timeout] overrides the default one-shot ceiling for the rare command that
  /// legitimately runs long — `grid agent install` downloads a private CPython
  /// and the agent's dependencies (minutes, not seconds, and slower still on an
  /// Intel Mac that builds wheels from source). Left null it keeps the short
  /// default, which suits the quick lifecycle calls (login/logout/sync/catalog).
  Future<CliResult> run(List<String> args, {Duration? timeout});

  /// Start a long-running command and return a handle to its output + lifetime.
  ///
  /// [environment] adds/overrides variables for this one spawn only, on top of
  /// the base environment. It's the channel for secrets the CLI reads from the
  /// environment (e.g. an API-engine key in `OPENAI_API_KEY`): passing them here
  /// instead of as argv keeps them out of the command line — and so out of the
  /// Debug tab and the CLI transcript, which log only [args] (mirrors the CLI's
  /// own "never a flag — a key on the command line leaks into shell history").
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  });

  /// Run `models pull` / `media pull`, surfacing parsed download progress.
  ///
  /// The stream ends with a [GridPullFailed] error when the CLI exits non-zero.
  /// It used to end cleanly whatever the exit code, so a `grid pull` that died
  /// on a 404 looked exactly like one that finished — in the app *and* in the
  /// transcript, which logged `exit=0` because nobody had read the real one.
  Stream<DownloadProgress> pull(List<String> args);
}

/// A `grid pull` that exited non-zero. [message] is the CLI's own last words on
/// stderr (empty when it said nothing), kept raw for the log — callers map it to
/// something a person can act on.
class GridPullFailed implements Exception {
  const GridPullFailed({required this.exitCode, required this.message});

  final int exitCode;
  final String message;

  @override
  String toString() => message.isEmpty
      ? 'grid pull failed (exit $exitCode)'
      : 'grid pull failed (exit $exitCode): $message';
}
