import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/onboarding/preflight_service.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

void main() {
  test('reports grid available from a successful --version', () async {
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: 'grid 0.2.0', stderr: ''));

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isTrue);
    expect(report.gridVersion, 'grid 0.2.0');
    expect(report.canProceed, isTrue);
  });

  test('a pre-0.2 grid is blocked: it has no `agent install` and needs brew',
      () async {
    // This CLI runs fine — it just can't do what the app now asks of it. Say so
    // here, in the app's voice, rather than dying inside a setup step later.
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: 'grid 0.1.15', stderr: ''));

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isFalse);
    expect(report.canProceed, isFalse);
    expect(report.gridError, contains('out of date'));
    expect(report.gridError, contains('0.2.0'));
  });

  test('grid available on exit 0 even when --version prints nothing', () async {
    // Regression: a clean exit already proves `grid` runs. Requiring non-empty
    // stdout falsely blocked the app with "did not run (exit 0)" — a version
    // string is display-only and some builds exit 0 without printing one.
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: '', stderr: ''));

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isTrue);
    expect(report.canProceed, isTrue);
    expect(report.gridVersion, isNull);
    expect(report.gridError, isNull);
  });

  test('macOS SIGKILL (exit -9) reads as a blocked helper, not "exit -9"',
      () async {
    // A signed/notarized or quarantined sidecar gets SIGKILL'd on launch; the
    // raw "-9" is meaningless to users, so surface the security cause + a fix.
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: -9, stdout: '', stderr: ''));

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isFalse);
    expect(report.gridError, isNotNull);
    expect(report.gridError, contains('blocked'));
    expect(report.gridError, isNot(contains('-9')));
  });

  test('other signal kills read as a crash', () async {
    final fake = FakeGridCliService()
      ..stubResult(['--version'],
          const CliResult(exitCode: -11, stdout: '', stderr: ''));

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isFalse);
    expect(report.gridError, contains('crashed'));
    expect(report.gridError, contains('11'));
  });

  test('grid absent when the service is null', () async {
    final report = await PreflightService(null).check();

    expect(report.gridAvailable, isFalse);
    expect(report.canProceed, isFalse);
  });

  test('grid present but crashing surfaces the CLI error', () async {
    final fake = FakeGridCliService()
      ..stubResult(
        ['--version'],
        const CliResult(
          exitCode: 1,
          stdout: '',
          stderr: 'ModuleNotFoundError: No module named \'grid.core\'',
        ),
      );

    final report = await PreflightService(fake).check();

    expect(report.gridAvailable, isFalse);
    expect(report.canProceed, isFalse);
    expect(report.gridError, isNotNull);
    expect(report.gridError, contains('ModuleNotFoundError'));
  });
}
