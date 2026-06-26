import 'dart:io';

import '../../infrastructure/cli/cli_diagnostics.dart';
import '../../infrastructure/cli/grid_cli_service.dart';
import 'preflight_report.dart';

/// Probes the host for the things the app depends on: a working `grid` binary
/// and (optionally) a container engine. Injectable so it can run against
/// [FakeGridCliService] and a stubbed executable check in tests.
class PreflightService {
  PreflightService(this._service, {bool Function(String exe)? hasExecutable})
      : _hasExecutable = hasExecutable ?? _whichExists;

  final GridCliService? _service;
  final bool Function(String exe) _hasExecutable;

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
      containerEngine: _hasExecutable('docker')
          ? 'docker'
          : _hasExecutable('podman')
              ? 'podman'
              : null,
    );
  }

  static bool _whichExists(String exe) {
    final locator = Platform.isWindows ? 'where' : 'which';
    try {
      return Process.runSync(locator, [exe]).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
