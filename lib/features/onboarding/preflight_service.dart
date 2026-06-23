import 'dart:io';

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
    if (_service != null) {
      final result = await _service.run(['--version']);
      if (result.ok && result.stdout.trim().isNotEmpty) {
        version = result.stdout.trim();
      }
    }
    return PreflightReport(
      gridAvailable: version != null,
      gridVersion: version,
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
