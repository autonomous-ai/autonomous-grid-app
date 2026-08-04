import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/command_log.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';
import 'package:grid_app/infrastructure/logging/http_log.dart';

/// Records every [AppLog] event so we can assert what the command log mirrored.
class _RecordingAppLog implements AppLog {
  final List<(AppLogLevel, String, String)> events = [];

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => events.add((level, category, message));
}

/// Records HTTP-log calls so we can assert the dedicated file was fed, and when.
class _RecordingHttpLog implements HttpLog {
  final List<(int, String)> started = [];
  final List<(int, int?, String?)> finished = [];

  @override
  void start(int id, String request) => started.add((id, request));

  @override
  void finish(int id, {int? statusCode, String? error, Duration? duration}) =>
      finished.add((id, statusCode, error));
}

void main() {
  late _RecordingAppLog appLog;
  late _RecordingHttpLog httpLog;
  late ProviderContainer container;
  late CommandLogNotifier log;

  setUp(() {
    appLog = _RecordingAppLog();
    httpLog = _RecordingHttpLog();
    container = ProviderContainer(
      overrides: [
        appLogProvider.overrideWithValue(appLog),
        httpLogProvider.overrideWithValue(httpLog),
      ],
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

  test(
    'writes an HTTP call to the dedicated file the instant it begins',
    () async {
      final id = log.begin(CliCallKind.http, 'POST https://api/x');

      // Written synchronously on begin — no need to pump the event queue.
      expect(httpLog.started.single, (id, 'POST https://api/x'));

      log.finish(id, exitCode: 200);
      await pumpEventQueue();
      expect(httpLog.finished.single, (id, 200, null));
    },
  );

  test('never writes a CLI call to the HTTP file', () async {
    final id = log.begin(CliCallKind.run, 'grid sync');
    log.finish(id, exitCode: 0);
    await pumpEventQueue();

    expect(httpLog.started, isEmpty);
    expect(httpLog.finished, isEmpty);
  });

  group('detail', () {
    test('keeps the request body a call was started with', () async {
      log.begin(
        CliCallKind.http,
        'POST https://api/chat',
        detail: CommandDetail.json(const {'model': 'qwen3', 'stream': true}),
      );
      await pumpEventQueue();

      final detail = container.read(commandLogProvider).single.detail;
      expect(detail.requestBody, '{"model":"qwen3","stream":true}');
    });

    test('records what came back only when the caller has it', () async {
      final id = log.begin(CliCallKind.http, 'POST https://api/chat');
      log.finish(id, exitCode: 200, responseBody: 'Hello there');
      await pumpEventQueue();

      expect(
        container.read(commandLogProvider).single.detail.responseBody,
        'Hello there',
      );
    });

    test('clips a body so one media payload cannot hold the buffer', () async {
      log.begin(
        CliCallKind.http,
        'POST https://api/media',
        // A base64 image arrives as a single line of megabytes; the ring buffer
        // holds 200 entries, so an unclipped one is the app's memory.
        detail: CommandDetail(requestBody: 'x' * (kMaxLoggedBody + 500)),
      );
      await pumpEventQueue();

      final body = container
          .read(commandLogProvider)
          .single
          .detail
          .requestBody!;
      expect(body.length, lessThan(kMaxLoggedBody + 100));
      expect(body, endsWith('… 500 more characters not kept'));
    });

    test('leaves a body shorter than the cap exactly as it was', () async {
      expect(clipLogBody('{"a":1}'), '{"a":1}');
      expect(clipLogBody(null), isNull);
    });

    test('a clipped body owns up to it, so a copy can say so too', () {
      expect(isClippedBody(clipLogBody('x' * (kMaxLoggedBody + 1))!), isTrue);
      expect(isClippedBody('{"a":1}'), isFalse);
    });

    test('carries the argv, the env names and the bearer flag through a '
        'finish', () async {
      final id = log.begin(
        CliCallKind.start,
        'grid join --api openai',
        detail: const CommandDetail(
          args: ['grid', 'join', '--api', 'openai'],
          envKeys: ['OPENAI_API_KEY'],
          authorized: true,
        ),
      );
      log.finish(id, exitCode: 0, responseBody: 'ok');
      await pumpEventQueue();

      final detail = container.read(commandLogProvider).single.detail;
      expect(detail.args, ['grid', 'join', '--api', 'openai']);
      expect(detail.envKeys, ['OPENAI_API_KEY']);
      expect(detail.authorized, isTrue);
      expect(detail.responseBody, 'ok');
    });
  });
}
