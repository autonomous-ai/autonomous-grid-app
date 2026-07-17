import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/file_logging_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/logging/cli_log.dart';

/// In-memory [CliLog] so tests observe what the decorator recorded without a
/// file. Records raw calls (no idempotency guard) to catch double-closes.
class _RecordingCliLog implements CliLog {
  final List<_Section> sections = [];

  @override
  CliLogEntry begin(String command) {
    final section = _Section(command);
    sections.add(section);
    return section;
  }
}

class _Section implements CliLogEntry {
  _Section(this.command);
  final String command;
  final List<String> outputs = [];
  int endCalls = 0;
  int? exitCode;
  String? error;

  @override
  void output(String line, {bool isError = false}) =>
      outputs.add('${isError ? 'ERR' : 'OUT'}:$line');

  @override
  void end({int? exitCode, Duration? duration, String? error}) {
    endCalls++;
    this.exitCode = exitCode;
    this.error = error;
  }
}

void main() {
  late FakeGridCliService inner;
  late _RecordingCliLog log;
  late FileLoggingGridCliService service;

  setUp(() {
    inner = FakeGridCliService();
    log = _RecordingCliLog();
    service = FileLoggingGridCliService(inner, log);
  });

  group('run', () {
    test(
      'logs the command, stdout, stderr split by line, and the exit code',
      () async {
        inner.stubResult(
          ['status'],
          const CliResult(
            exitCode: 2,
            stdout: 'line1\nline2\n',
            stderr: 'oops',
          ),
        );

        final result = await service.run(['status']);

        expect(result.exitCode, 2); // pass-through unchanged
        final section = log.sections.single;
        expect(section.command, 'grid status');
        expect(section.outputs, ['OUT:line1', 'OUT:line2', 'ERR:oops']);
        expect(section.exitCode, 2);
        expect(section.endCalls, 1);
      },
    );

    test('skips empty stdout/stderr blocks', () async {
      inner.stubResult([
        'whoami',
      ], const CliResult(exitCode: 0, stdout: '', stderr: ''));

      await service.run(['whoami']);

      expect(log.sections.single.outputs, isEmpty);
    });
  });

  group('start', () {
    test(
      'tees every line to the caller and the log, then records the exit',
      () async {
        inner.stubStart(
          ['login'],
          lines: const [
            CliLine(isStderr: false, text: 'visit https://grid/device'),
            CliLine(isStderr: true, text: 'warning'),
          ],
        );

        final process = await service.start(['login']);
        final delivered = await process.lines.toList();
        await process.exitCode;

        // Caller still receives the exact stream.
        expect(delivered.map((l) => l.text), [
          'visit https://grid/device',
          'warning',
        ]);

        final section = log.sections.single;
        expect(section.command, 'grid login');
        expect(section.outputs, [
          'OUT:visit https://grid/device',
          'ERR:warning',
        ]);
        expect(section.exitCode, 0);
        expect(section.endCalls, 1);
      },
    );
  });

  group('pull', () {
    test('passes progress through and logs begin + final state', () async {
      inner.stubPull(
        ['models', 'pull', 'x'],
        const [
          DownloadProgress(doneMb: 10),
          DownloadProgress(doneMb: 100, totalMb: 200, pct: 50),
        ],
      );

      final seen = await service.pull(['models', 'pull', 'x']).toList();

      expect(seen.map((p) => p.doneMb), [10, 100]); // pass-through unchanged
      final section = log.sections.single;
      expect(section.command, 'grid models pull x');
      expect(section.outputs, ['OUT:downloaded 100.0 / 200.0 MB (50.0%)']);
      expect(section.exitCode, 0);
      expect(section.endCalls, 1);
    });

    test('logs an indeterminate final state when total is unknown', () async {
      inner.stubPull(
        ['media', 'pull', 'y'],
        const [DownloadProgress(doneMb: 42.5)],
      );

      await service.pull(['media', 'pull', 'y']).toList();

      expect(log.sections.single.outputs, ['OUT:downloaded 42.5 MB']);
    });
  });
}
