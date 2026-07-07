import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/command_log.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';

/// Records every [AppLog] event so we can assert what the command log mirrored.
class _RecordingAppLog implements AppLog {
  final List<(AppLogLevel, String, String)> events = [];

  @override
  void record(AppLogLevel level, String category, String message,
          {Object? error, StackTrace? stackTrace}) =>
      events.add((level, category, message));
}

void main() {
  late _RecordingAppLog appLog;
  late ProviderContainer container;
  late CommandLogNotifier log;

  setUp(() {
    appLog = _RecordingAppLog();
    container = ProviderContainer(
      overrides: [appLogProvider.overrideWithValue(appLog)],
    );
    log = container.read(commandLogProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('mirrors a successful CLI call to the app-log timeline', () async {
    final id = log.begin(CliCallKind.run, 'grid --remote login');
    log.finish(id, exitCode: 0);
    await pumpEventQueue();

    final event = appLog.events.single;
    expect(event.$1, AppLogLevel.info);
    expect(event.$2, 'cli');
    expect(event.$3, startsWith('grid --remote login → ok exit=0'));
  });

  test('mirrors a failed HTTP call at error level with the status', () async {
    final id = log.begin(CliCallKind.http, 'POST https://api/x');
    log.finish(id, exitCode: 500);
    await pumpEventQueue();

    final event = appLog.events.single;
    expect(event.$1, AppLogLevel.error);
    expect(event.$2, 'api');
    expect(event.$3, contains('FAILED status=500'));
  });

  test('mirrors only on finish, never on begin', () async {
    log.begin(CliCallKind.run, 'grid sync');
    await pumpEventQueue();
    expect(appLog.events, isEmpty);
  });

  test('carries the friendly error message into the timeline', () async {
    final id = log.begin(CliCallKind.run, 'grid join');
    log.finish(id, error: 'engine crashed');
    await pumpEventQueue();

    expect(appLog.events.single.$3, endsWith(': engine crashed'));
  });
}
