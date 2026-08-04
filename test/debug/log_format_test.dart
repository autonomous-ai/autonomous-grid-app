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

  group('shell quoting', () {
    test('leaves a plain argument bare and wraps one with a space', () {
      expect(shellQuote('--remote'), '--remote');
      expect(shellQuote('My home grid'), "'My home grid'");
    });

    test("breaks out an argument's own quote instead of ending the word", () {
      // Unescaped, this closes the quote and the rest becomes new arguments.
      expect(shellQuote("it's here"), r"'it'\''s here'");
    });
  });

  group('a request copies as curl', () {
    test('carries the method, the headers it sent, and the body', () {
      final copied = logAsCommand(
        _log(
          command: 'POST https://grid.autonomous.ai/relay/v1/chat/completions',
          exitCode: 200,
          duration: const Duration(milliseconds: 318),
          detail: CommandDetail.json(const {
            'model': 'qwen3',
          }, authorized: true),
        ),
      );

      expect(
        copied,
        contains(
          "curl -sS -X POST 'https://grid.autonomous.ai/relay/v1/"
          "chat/completions'",
        ),
      );
      expect(copied, contains("-H 'Content-Type: application/json'"));
      expect(copied, contains(r'-H "Authorization: Bearer $GRID_API_KEY"'));
      expect(copied, contains(r"""-d '{"model":"qwen3"}'"""));
      // The key is named, never carried.
      expect(copied, contains('export GRID_API_KEY'));
    });

    test('a plain GET needs neither -X nor a body flag', () {
      final copied = logAsCommand(_log(exitCode: 200));

      expect(copied, contains("curl -sS 'https://api-grid.autonomous.ai"));
      expect(copied, isNot(contains('-X')));
      expect(copied, isNot(contains('-d')));
      expect(copied, isNot(contains('Authorization')));
    });

    test('says so when the body it hands over was clipped for the log', () {
      final clipped = clipLogBody('x' * (kMaxLoggedBody + 20))!;
      final copied = logAsCommand(
        _log(
          command: 'POST https://api/media',
          detail: CommandDetail(requestBody: clipped),
        ),
      );

      // Otherwise this reads as a request you can repeat, and it isn't.
      expect(copied, contains('# NOTE: the body below was clipped'));
    });

    test('the outcome rides above it as comments a shell will ignore', () {
      final copied = logAsCommand(
        _log(
          status: CliCallStatus.failed,
          exitCode: 502,
          duration: const Duration(milliseconds: 900),
          error: 'upstream gateway said no',
        ),
      );

      final lines = copied.split('\n');
      expect(lines.first, '# GET → HTTP 502 · 900ms · started 11:37:05');
      expect(lines[1], '# upstream gateway said no');
      expect(lines.where((l) => l.startsWith('curl')), hasLength(1));
    });
  });

  group('a spawned process copies as its own command line', () {
    test('quotes each argument and reads its secrets from the terminal', () {
      final copied = logAsCommand(
        _log(
          kind: CliCallKind.run,
          command: 'grid network rename --name My home grid',
          exitCode: 0,
          detail: const CommandDetail(
            args: ['grid', 'network', 'rename', '--name', 'My home grid'],
            envKeys: ['OPENAI_API_KEY'],
          ),
        ),
      );

      expect(
        copied,
        contains(
          'OPENAI_API_KEY="\$OPENAI_API_KEY" grid network rename '
          "--name 'My home grid'",
        ),
      );
      expect(copied, contains('# needs: OPENAI_API_KEY'));
      expect(copied, isNot(contains('curl')));
    });

    test('pipes the prompt back in, because that is how it was sent', () {
      final copied = logAsCommand(
        _log(
          kind: CliCallKind.start,
          command: 'codex exec -m qwen3 (agent)',
          detail: const CommandDetail(
            args: ['codex', 'exec', '--json'],
            requestBody: 'Summarise this branch',
          ),
        ),
      );

      // The opening tag is quoted so nothing in the prompt is expanded; the
      // closing one must be bare, or the shell never finds the end.
      expect(
        copied,
        endsWith(
          "codex exec --json <<'GRID_PROMPT'\n"
          'Summarise this branch\n'
          'GRID_PROMPT',
        ),
      );
    });

    test('falls back to the facts when there is no command to re-run', () {
      // A Hermes turn goes down a session that is already open.
      final copied = logAsCommand(
        _log(
          kind: CliCallKind.start,
          command: 'hermes acp -m qwen3 (agent)',
          detail: const CommandDetail(requestBody: 'Summarise this branch'),
        ),
      );

      expect(copied, contains('# hermes acp -m qwen3 (agent)'));
      expect(copied, contains('Summarise this branch'));
    });
  });

  test('the copy button says which of the two it will hand over', () {
    expect(copyActionLabel(_log()), 'Copy as curl');
    expect(
      copyActionLabel(
        _log(
          kind: CliCallKind.run,
          detail: const CommandDetail(args: ['grid', 'sync']),
        ),
      ),
      'Copy command',
    );
    expect(copyActionLabel(_log(kind: CliCallKind.start)), 'Copy details');
  });
}
