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
}

/// One line emitted by a long-running command (provider/install logs, §3.5).
class CliLine {
  const CliLine({required this.isStderr, required this.text});

  final bool isStderr;
  final String text;
}

/// A handle to a running, app-owned `grid` process. Used where we need both the
/// live output (e.g. the device-login URL mid-stream) and the final exit code,
/// and where we may need to kill it (e.g. `provider start` on window close —
/// loại 2 in the contract's process model).
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
  Future<CliResult> run(List<String> args);

  /// Start a long-running command and return a handle to its output + lifetime.
  Future<GridProcess> start(List<String> args);

  /// Run `models pull` / `media pull`, surfacing parsed download progress.
  Stream<DownloadProgress> pull(List<String> args);
}
