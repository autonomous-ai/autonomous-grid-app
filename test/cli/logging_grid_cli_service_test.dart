import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/command_log.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/logging_grid_cli_service.dart';

void main() {
  late FakeGridCliService inner;
  late ProviderContainer container;
  late LoggingGridCliService service;

  setUp(() {
    inner = FakeGridCliService();
    container = ProviderContainer();
    service = LoggingGridCliService(
      inner,
      container.read(commandLogProvider.notifier),
    );
  });

  tearDown(() => container.dispose());

  GridCommandLog entry() => container.read(commandLogProvider).single;

  test('keeps each argument separately, not just the joined line', () async {
    inner.stubResult([
      'network',
      'rename',
      '--name',
      'My home grid',
    ], const CliResult(exitCode: 0, stdout: '', stderr: ''));

    await service.run(['network', 'rename', '--name', 'My home grid']);
    await pumpEventQueue();

    // The joined line can't say whether that was one argument or three; the
    // recorded argv can, which is the point of keeping it. `grid` leads it so
    // the Debug tab can hand the whole thing back as a command that runs.
    expect(entry().detail.args, [
      'grid',
      'network',
      'rename',
      '--name',
      'My home grid',
    ]);
  });

  test(
    'records the names of environment overrides but never a value',
    () async {
      inner.stubStart(['join', '--api', 'openai'], lines: const []);

      final process = await service.start(
        ['join', '--api', 'openai'],
        environment: {'OPENAI_API_KEY': 'sk-do-not-log-me'},
      );
      // A started process is only logged as finished when it exits, and that
      // arrives on a later turn of the loop — so the exit is awaited here
      // rather than left to land after the test (and its container) are gone.
      await process.exitCode;
      await pumpEventQueue();

      final detail = entry().detail;
      expect(detail.envKeys, ['OPENAI_API_KEY']);
      // The whole entry, however it is later formatted, must not hold the key.
      expect('${detail.envKeys}${detail.params}', isNot(contains('sk-do-not')));
    },
  );

  test('records no environment names when a command sets none', () async {
    inner.stubStart(['sync'], lines: const []);

    final process = await service.start(['sync']);
    await process.exitCode;
    await pumpEventQueue();

    expect(entry().detail.envKeys, isEmpty);
  });
}
