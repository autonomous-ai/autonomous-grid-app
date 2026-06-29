import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

void main() {
  group('CliResult.sessionExpired', () {
    test('true when the CLI reports an expired/invalid session', () {
      const result = CliResult(
        exitCode: 1,
        stdout: '',
        stderr:
            'Grid session expired or invalid. Run `grid auth login` to sign in again.',
      );
      expect(result.ok, isFalse);
      expect(result.sessionExpired, isTrue);
    });

    test('case-insensitive and tolerant of surrounding text', () {
      const result = CliResult(
        exitCode: 1,
        stdout: 'GRID SESSION EXPIRED OR INVALID.',
        stderr: '',
      );
      expect(result.sessionExpired, isTrue);
    });

    test('false on success even if the phrase appears', () {
      const result = CliResult(
        exitCode: 0,
        stdout: 'session expired or invalid',
        stderr: '',
      );
      expect(result.sessionExpired, isFalse);
    });

    test('false for unrelated failures', () {
      const result = CliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Network unreachable',
      );
      expect(result.sessionExpired, isFalse);
    });
  });
}
