import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/task_runner.dart';

String _script(TaskRunner runner, {String prompt = 'check the deploy'}) =>
    taskRunnerScript(
      runner: runner,
      prompt: prompt,
      workdir: '/Users/x/WorkPlace/app',
      pathDirs: const ['/Users/x/.local/bin', '/Users/x/.nvm/node/bin'],
    );

void main() {
  group('the script that lets a scheduled task answer as Claude or Codex', () {
    test(
      'runs the agent the task was set up with, not the scheduler\'s own',
      () {
        expect(_script(TaskRunner.claude), contains('claude -p'));
        expect(_script(TaskRunner.codex), contains('codex exec'));
      },
    );

    test('cd\'s to the task\'s folder — a scripted job starts in Hermes\'s '
        'scripts folder and --workdir does not move it', () {
      expect(
        _script(TaskRunner.claude),
        contains("cd '/Users/x/WorkPlace/app'"),
      );
    });

    test('names the folders the binaries are in — the scheduler is a daemon '
        'and carries none of the login shell\'s PATH', () {
      final script = _script(TaskRunner.claude);

      expect(script, contains('/Users/x/.local/bin'));
      expect(script, contains('/Users/x/.nvm/node/bin'));
      // The system dirs still follow, and only once.
      expect('/usr/bin:'.allMatches(script), hasLength(1));
    });

    test('hands over the tools the run needs, because headless the agent '
        'refuses every tool it was not given and asks nobody', () {
      expect(_script(TaskRunner.claude), contains('--allowedTools'));
    });

    test('quotes the folder it runs in, so a path with a \$ or a quote in it '
        'is one word rather than a broken script', () {
      final script = taskRunnerScript(
        runner: TaskRunner.claude,
        prompt: 'x',
        workdir: r"/Users/x/it's \$HOME/app",
        pathDirs: const ['/bin'],
      );

      expect(script, contains(r"cd '/Users/x/it'\''s \$HOME/app'"));
    });

    test('carries the prompt in a quoted heredoc, so a backtick in the user\'s '
        'own wording cannot become a command', () {
      final script = _script(
        TaskRunner.claude,
        prompt: 'report on `rm -rf /` and \$HOME and "quotes"',
      );

      expect(script, contains("<<'GRID_TASK_PROMPT_EOF"));
      expect(script, contains('report on `rm -rf /` and \$HOME and "quotes"'));
    });
  });

  group('naming the script file', () {
    test(
      'reads as the task it runs, in a shape a shell never has to quote',
      () {
        expect(
          taskScriptName('Nightly UI review', 'review the diff'),
          startsWith('grid-task-nightly-ui-review-'),
        );
        expect(
          taskScriptName('Café news — 8h!', 'read the news'),
          startsWith('grid-task-caf-news-8h-'),
        );
      },
    );

    test('two tasks sharing a name get different files — sharing one meant the '
        'first silently started answering the second one\'s prompt', () {
      expect(
        taskScriptName('Nightly review', 'review the diff'),
        isNot(taskScriptName('Nightly review', 'review the logs')),
      );
    });

    test('the same task names the same file on every launch, or the job would '
        'point at a script that moved', () {
      expect(
        taskScriptName('Nightly review', 'review the diff'),
        taskScriptName('Nightly review', 'review the diff'),
      );
    });

    test('a task named in a script nobody could address still gets a file, '
        'rather than one called `grid-task-.sh`', () {
      expect(taskScriptName('***', 'x'), startsWith('grid-task-unnamed-'));
      expect(taskScriptName('', 'x'), startsWith('grid-task-unnamed-'));
    });
  });
}
