import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/onboarding/preflight_service.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

void main() {
  test('reports grid available and the container engine', () async {
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: 'grid 0.1.0', stderr: ''));

    final report =
        await PreflightService(fake, hasExecutable: (e) => e == 'docker')
            .check();

    expect(report.gridAvailable, isTrue);
    expect(report.gridVersion, 'grid 0.1.0');
    expect(report.containerEngine, 'docker');
    expect(report.canProceed, isTrue);
  });

  test('grid absent when the service is null', () async {
    final report =
        await PreflightService(null, hasExecutable: (_) => false).check();

    expect(report.gridAvailable, isFalse);
    expect(report.canProceed, isFalse);
    expect(report.hasContainerEngine, isFalse);
  });

  test('grid present but crashing reports a clear arch error', () async {
    final fake = FakeGridCliService()
      ..stubResult(
        ['--version'],
        const CliResult(
          exitCode: 1,
          stdout: '',
          stderr: "ImportError: dlopen(protocol.cpython-313-darwin.so): "
              "mach-o file, but is an incompatible architecture "
              "(have 'arm64', need 'x86_64')",
        ),
      );

    final report =
        await PreflightService(fake, hasExecutable: (_) => false).check();

    expect(report.gridAvailable, isFalse);
    expect(report.canProceed, isFalse);
    expect(report.gridError, isNotNull);
    expect(report.gridError, contains('architecture'));
    expect(report.gridError, contains('Rosetta'));
  });

  test('falls back to podman when docker is missing', () async {
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: 'grid 0.1.0', stderr: ''));

    final report =
        await PreflightService(fake, hasExecutable: (e) => e == 'podman')
            .check();

    expect(report.containerEngine, 'podman');
  });
}
