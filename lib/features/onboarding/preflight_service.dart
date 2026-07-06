import '../../infrastructure/cli/cli_diagnostics.dart';
import '../../infrastructure/cli/grid_cli_service.dart';
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
      return PreflightReport(
        gridAvailable: true,
        gridVersion: version.isNotEmpty ? version : null,
      );
    }

    // Non-zero exit: `grid` is present but couldn't run (e.g. a missing Python
    // dependency). Capture *why*, clearly, so onboarding can explain it instead
    // of a generic "couldn't find grid".
    final gridError = diagnoseCliFailure(
      '${result.stdout}\n${result.stderr}'.split('\n'),
      headline: "The grid CLI couldn't start (exit ${result.exitCode}).",
    );
    return PreflightReport(
      gridAvailable: false,
      gridVersion: null,
      gridError: gridError,
    );
  }
}
