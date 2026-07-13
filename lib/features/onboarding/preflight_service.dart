import '../../infrastructure/cli/cli_diagnostics.dart';
import '../../infrastructure/cli/grid_cli_service.dart';
import 'grid_version.dart';
import 'preflight_report.dart';

/// Probes the host for the one thing the app depends on: a working `grid`
/// binary. Injectable so it can run against [FakeGridCliService] in tests.
class PreflightService {
  PreflightService(this._service);

  final GridCliService? _service;

  Future<PreflightReport> check() async {
    // No resolved binary at all — `grid` is simply not installed.
    if (_service == null) {
      return const PreflightReport(gridAvailable: false, gridVersion: null);
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
        return PreflightReport(
          gridAvailable: false,
          gridVersion: printed,
          gridError: outdatedGridMessage(printed),
        );
      }

      return PreflightReport(gridAvailable: true, gridVersion: printed);
    }

    // Non-zero exit: `grid` is present but couldn't run. A *negative* exit code
    // means the OS terminated it with a signal rather than the CLI failing
    // cleanly — so there's no stderr to show and the fix is different. On macOS
    // a SIGKILL (exit -9) is almost always Gatekeeper/AMFI blocking a helper
    // that isn't signed/notarized or still carries the download quarantine flag;
    // say so in plain terms instead of a cryptic "exit -9".
    final gridError = _signalError(result.exitCode) ??
        diagnoseCliFailure(
          '${result.stdout}\n${result.stderr}'.split('\n'),
          headline: "The grid CLI couldn't start (exit ${result.exitCode}).",
        );
    return PreflightReport(
      gridAvailable: false,
      gridVersion: null,
      gridError: gridError,
    );
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
