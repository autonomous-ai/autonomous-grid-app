import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/onboarding/preflight_providers.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// A [FakeGridCliService] that records the lifecycle commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _containerWith(GridCliService cli) {
  final container = ProviderContainer(
    overrides: [gridCliServiceProvider.overrideWithValue(cli)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('runs grid sync right after a successful version check', () async {
    final cli = _RecordingCli()
      ..stubResult(['--version'],
          const CliResult(exitCode: 0, stdout: 'grid 0.1.0', stderr: ''));
    final container = _containerWith(cli);

    final report = await container.read(preflightProvider.future);

    expect(report.gridAvailable, isTrue);
    expect(cli.runs.first, ['--version']);
    expect(cli.runs, contains(equals(const ['sync'])));
  });

  test('skips sync when the grid CLI is unavailable', () async {
    final cli = _RecordingCli()
      ..stubResult(['--version'],
          const CliResult(exitCode: 1, stdout: '', stderr: 'boom'));
    final container = _containerWith(cli);

    final report = await container.read(preflightProvider.future);

    expect(report.gridAvailable, isFalse);
    expect(cli.runs, isNot(contains(equals(const ['sync']))));
  });
}
