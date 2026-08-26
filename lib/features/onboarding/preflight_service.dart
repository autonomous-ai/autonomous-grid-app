import '../../infrastructure/cli/cli_diagnostics.dart';
import '../../infrastructure/cli/grid_cli_service.dart';
import '../../infrastructure/cli/grid_resolution.dart';
import 'grid_version.dart';
import 'preflight_report.dart';

/// Probes the host for the one thing the app depends on: a working `grid`
/// binary. Injectable so it can run against [FakeGridCliService] in tests.
class PreflightService {
  PreflightService(this._service, this._resolution);

  final GridCliService? _service;

  /// What the resolver found and — when it found nothing — what it rejected on
  /// the way. Without this, a sidecar skipped for its architecture is
  /// indistinguishable from a machine that never had `grid` at all.
  final GridResolution _resolution;

  Future<PreflightReport> check() async {
    // No resolved binary at all: either `grid` is simply not installed, or the
    // helper we ship can't run on this CPU.
    if (_service == null) {
      final wrongArch = _resolution.wrongArchSidecar;
      return PreflightReport.blocked(
        wrongArch != null
            ? GridWrongArch(wrongArch)
            : GridMissing(_resolution.probed),
      );
    }

    final result = await _service.run(['--version']);

    // A clean exit means `grid` was found, launched, and ran to completion —
    // which is all preflight gates on. The printed version is best-effort
    // *display* only: some builds (e.g. a source checkout with no package
    // metadata) exit 0 without printing one, and that must never read as
    // "broken" — gating on non-empty stdout used to false-alarm with the
    // self-contradictory "did not run (exit 0)" after a CLI upgrade.
    if (result.ok) {
      final version = result.stdout.trim();
      final printed = version.isNotEmpty ? version : null;

      // A CLI that runs but is too old is as unusable as one that's missing —
      // it has no `agent install`, and its `engine install` still demands
      // Homebrew. Fail here, in the app's voice, instead of deep inside a setup
      // the user can't interpret.
      if (!isSupportedGridVersion(parseGridVersion(version))) {
        return PreflightReport.blocked(
          GridUnusable(outdatedGridMessage(printed)),
          gridVersion: printed,
        );
      }

      return PreflightReport.ready(printed);
    }

    return PreflightReport.blocked(_failure(result));
  }

  /// Why a non-`ok` `grid --version` failed, in words a user can act on.
  PreflightIssue _failure(CliResult result) {
    switch (result.outcome) {
      // The app gave up waiting, which is not a crash and not a missing helper:
      // say so, and don't dress -1 up as a signal (it used to read as
      // "crashed … (signal 1)", which sent people looking for the wrong thing).
      case CliOutcome.timedOut:
        return const GridUnusable(
          "The Grid helper didn't respond in time. Quit Grid, reopen it, and "
          'check again.',
        );
      // A CPU mismatch the resolver could not see — the sidecar's header parsed
      // as runnable (or this is an Intel build on an Apple Silicon Mac with no
      // Rosetta), and the OS refused it only at spawn time.
      case CliOutcome.spawnFailed:
        final path = _resolution.path;
        if (_isCpuMismatch(result.errorMessage) && path != null) {
          return GridWrongArch(path);
        }
        return GridUnusable(
          "The Grid helper wouldn't start: ${result.errorMessage}",
        );
      case CliOutcome.completed:
        return GridUnusable(
          _signalError(result.exitCode) ??
              diagnoseCliFailure(
                '${result.stdout}\n${result.stderr}'.split('\n'),
                headline:
                    "The grid CLI couldn't start (exit ${result.exitCode}).",
              ),
        );
    }
  }

  /// The OS refusing a binary built for another architecture. macOS words it
  /// "Bad CPU type in executable"; Linux's is "Exec format error".
  static bool _isCpuMismatch(String message) {
    final text = message.toLowerCase();
    return text.contains('bad cpu type') || text.contains('exec format error');
  }

  /// A user-facing message when `grid` was killed by a signal (negative exit),
  /// or null for an ordinary non-zero exit. macOS SIGKILL means the OS blocked
  /// the helper (unsigned / quarantined); other signals mean it crashed.
  String? _signalError(int exitCode) {
    if (exitCode >= 0) return null;
    if (exitCode == -9) {
      return 'macOS blocked the Grid helper from starting — it may be '
          'unsigned or still quarantined. Reinstall Grid from the official '
          'installer, then check again.';
    }
    return 'The Grid helper crashed before it could start (signal '
        '${-exitCode}). Reinstall Grid, then check again.';
  }
}
