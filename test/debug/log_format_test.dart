import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/debug/logic/log_format.dart';
import 'package:grid_app/infrastructure/cli/command_log.dart';

GridCommandLog _log({
  CliCallKind kind = CliCallKind.http,
  String command = 'GET https://api-grid.autonomous.ai/v1/grid/networks',
  CliCallStatus status = CliCallStatus.success,
  int? exitCode,
  Duration? duration,
  String? error,
  CommandDetail detail = const CommandDetail(),
}) => GridCommandLog(
  id: 1,
  kind: kind,
  command: command,
  startedAt: DateTime(2026, 8, 4, 11, 37, 5),
  status: status,
  exitCode: exitCode,
  duration: duration,
  error: error,
  detail: detail,
);

void main() {
  group('query parameters', () {
    test('splits a URL query so each one reads as its own fact', () {
      final params = logQueryParams(
        _log(command: 'GET https://api/v1/models?json=true&limit=20'),
      );

      expect(params, {'json': 'true', 'limit': '20'});
    });

    test('finds none in a CLI line that happens to contain a "?"', () {
      final params = logQueryParams(
        _log(kind: CliCallKind.run, command: 'grid ask "what now?"'),
      );

      expect(params, isEmpty);
    });
  });

  group('body formatting', () {
    test('re-indents a JSON body, where a one-line payload hides a field', () {
      expect(
        prettyBody('{"model":"qwen3","stream":true}'),
        '{\n  "model": "qwen3",\n  "stream": true\n}',
      );
    });

    test('shows a plain-text body untouched instead of a parse error', () {
      expect(prettyBody('Summarise this file'), 'Summarise this file');
    });
  });

  test('durations read in the shortest honest unit', () {
    expect(formatLogDuration(const Duration(milliseconds: 174)), '174ms');
    expect(formatLogDuration(const Duration(milliseconds: 1400)), '1.4s');
    expect(formatLogDuration(const Duration(seconds: 62)), '62s');
  });

  group('copy-all text', () {
    test('carries every recorded fact, so a paste needs no screenshot', () {
      final text = logAsText(
        _log(
          kind: CliCallKind.run,
          command: 'grid --remote join --api openai',
          exitCode: 1,
          duration: const Duration(milliseconds: 1400),
          error: 'no seat available',
          detail: const CommandDetail(
            args: ['--remote', 'join', '--api', 'openai'],
            params: {'env': 'OPENAI_API_KEY — values hidden'},
          ),
        ),
      );

      expect(text, contains('grid --remote join --api openai'));
      expect(text, contains('started: 11:37:05'));
      expect(text, contains('took: 1.4s'));
      expect(text, contains('exit: 1'));
      expect(text, contains('error: no seat available'));
      expect(text, contains('  --api'));
      expect(text, contains('env: OPENAI_API_KEY — values hidden'));
    });

    test('calls an HTTP result a status, never an exit code', () {
      final text = logAsText(_log(exitCode: 502));

      expect(text, contains('status: 502'));
      expect(text, isNot(contains('exit:')));
    });
  });
}
