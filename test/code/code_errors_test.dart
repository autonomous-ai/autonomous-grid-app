import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_errors.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

CliResult _failed(String stderr, {int exitCode = 2}) =>
    CliResult(exitCode: exitCode, stdout: '', stderr: stderr);

void main() {
  group('telling an out-of-date grid tool apart from a real failure', () {
    test('argparse’s unknown-command answer is recognised, not shown', () {
      // Its own words are a list of every command it *does* have, with the
      // missing one nowhere in it — which reads as something being broken.
      expect(
        cliLacksCodeCommands(
          _failed(
            "grid: error: argument <command>: invalid choice: 'task' "
            "(choose from 'version', 'up', 'join')",
          ),
        ),
        isTrue,
      );
      expect(
        cliLacksCodeCommands(
          _failed("invalid choice: 'project' (choose from 'version')"),
        ),
        isTrue,
      );
    });

    test('a task whose own text mentions the word is not mistaken for it', () {
      // Both halves have to be present, or a prompt could trip this.
      expect(
        cliLacksCodeCommands(
          _failed("Task 't-1' not found — check `grid task list`."),
        ),
        isFalse,
      );
    });

    test('a command that worked is never read as a missing command', () {
      expect(
        cliLacksCodeCommands(
          const CliResult(exitCode: 0, stdout: '{}', stderr: ''),
        ),
        isFalse,
      );
    });
  });

  group('what a person is shown when a command fails', () {
    test('an expired session is answered by the app, not by the terminal', () {
      expect(
        friendlyCodeError(
          _failed(
            "You're not signed in. Run `grid login` to sign in.",
            exitCode: 1,
          ),
        ),
        contains('sign in again'),
      );
    });

    test('a bare transport failure becomes a sentence about the grid', () {
      expect(
        friendlyCodeError(
          _failed('Cannot reach the relay (GET /relay/v1/tasks): timed out'),
        ),
        contains('may be offline'),
      );
    });

    test(
      'the grid’s own refusal is passed through, because it is the better one',
      () {
        // "Behind main, so a promote would be refused. Fix it with…" already
        // names what happened and what to do; rewriting it would lose detail.
        const refusal = 'You already have an active task in project P1 (T7).';
        expect(friendlyCodeError(_failed(refusal)), refusal);
      },
    );

    test('a command that said nothing still gets a sentence', () {
      expect(friendlyCodeError(_failed('')), contains('Check your connection'));
    });

    test('a runaway message is cut rather than allowed to fill a dialog', () {
      final long = friendlyCodeError(_failed('x' * 900));
      expect(long.length, lessThanOrEqualTo(400));
      expect(long, endsWith('…'));
    });
  });
}
