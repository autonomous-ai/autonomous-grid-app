import '../../infrastructure/cli/cli_diagnostics.dart';
import '../../infrastructure/cli/grid_cli_service.dart';
import 'preflight_report.dart';

/// Probes the host for the one thing the app depends on: a working `grid`
/// binary. Injectable so it can run against [FakeGridCliService] in tests.
class PreflightService {
  PreflightService(this._service);

  final GridCliService? _service;

  Future<PreflightReport> check() async {
    String? version;
    String? gridError;
    if (_service != null) {
      final result = await _service.run(['--version']);
      if (result.ok && result.stdout.trim().isNotEmpty) {
        version = result.stdout.trim();
      } else {
        // `grid` is present but didn't run — capture *why*, clearly, so the
        // onboarding screen can explain it instead of "couldn't find grid".
        gridError = diagnoseCliFailure(
          '${result.stdout}\n${result.stderr}'.split('\n'),
          headline: 'The grid CLI did not run (exit ${result.exitCode}).',
        );
      }
    }
    return PreflightReport(
      gridAvailable: version != null,
      gridVersion: version,
      gridError: version == null ? gridError : null,
    );
  }
}
