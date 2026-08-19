import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/host_environment.dart';
import '../../agents/logic/agent_catalog.dart';

/// Which assistant answers a scheduled task when it fires.
///
/// Hermes owns the scheduler, so its own agent was the only thing that ever ran
/// a task — including tasks set up in a chat with Claude Code or Codex, whose
/// tools, skills and model the run then didn't have. The user picked an
/// assistant to talk to; the task they asked it to repeat has to be answered by
/// the same one.
enum TaskRunner {
  /// Hermes answers the prompt itself — the scheduler's own path, and the only
  /// one before 2026-08-19.
  hermes,

  /// Claude Code answers it, driven by a script the scheduler runs.
  claude,

  /// Codex answers it, the same way.
  codex;

  /// The agent behind this runner, for naming it to the user.
  AgentTool get agent => switch (this) {
    TaskRunner.hermes => AgentTool.hermes,
    TaskRunner.claude => AgentTool.claude,
    TaskRunner.codex => AgentTool.codex,
  };

  /// Whether the scheduler runs a script instead of asking its own agent.
  bool get isScripted => this != TaskRunner.hermes;
}

/// Where Hermes keeps the scripts a task may run. Its own folder, and the only
/// place `--script` will look.
Directory get taskScriptsDir =>
    Directory('${GridPaths.userHome}/.hermes/scripts');

/// The script file name for a task called [name].
///
/// Named after the task rather than its id because the id doesn't exist until
/// Hermes has created the job, and the job needs the script's name to be
/// created. Two tasks with the same name share one script, which is the same
/// thing their prompts would say.
String taskScriptName(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  return 'grid-task-${slug.isEmpty ? 'unnamed' : slug}.sh';
}

/// The delimiter closing the prompt heredoc. Long and unlovely so a prompt that
/// happens to contain it is not a thing that happens.
const String _kPromptEnd = 'GRID_TASK_PROMPT_EOF_9f2c';

/// The bash a scheduled task runs to have [runner] answer [prompt] in [workdir].
///
/// Every line here is one the scheduler will not do for you, each measured on
/// 2026-08-19 against a real `--script --no-agent` job rather than assumed:
///
/// - **`cd`** — a scripted job starts in `~/.hermes/scripts`, and `--workdir`
///   does not move it.
/// - **`PATH`** — the scheduler is a daemon started by launchd. It carries none
///   of the login shell's PATH, so `claude`, `codex` and the `node` they need
///   are not on it unless named here.
/// - **the tool grant** — headless, an agent refuses every tool it was not
///   handed, mid-run and without asking anyone. A task that may not read a file
///   is a task that reports it couldn't do the work.
///
/// The prompt goes in on stdin through a quoted heredoc: it is the user's own
/// text, arbitrarily long, and quoting it any other way is how a stray backtick
/// becomes a command.
String taskRunnerScript({
  required TaskRunner runner,
  required String prompt,
  required String workdir,
  required List<String> pathDirs,
}) {
  const fallback = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'];
  final path = [
    for (final dir in pathDirs)
      if (dir.trim().isNotEmpty && !fallback.contains(dir)) dir,
    ...fallback,
  ].join(':');
  final invocation = switch (runner) {
    TaskRunner.claude =>
      'claude -p "\$PROMPT" --allowedTools Bash Read Write Edit Glob Grep',
    TaskRunner.codex => 'codex exec "\$PROMPT"',
    // Hermes answers its own prompts; nothing scripts it.
    TaskRunner.hermes => 'echo "no script runs Hermes"',
  };
  return '''
#!/bin/bash
# Written by Grid — a scheduled task answered by ${runner.agent.name}.
# Edit the task in Grid rather than here: saving it writes this file again.
set -uo pipefail
export PATH="$path"
cd "$workdir" || exit 1

PROMPT="\$(cat <<'$_kPromptEnd'
$prompt
$_kPromptEnd
)"

$invocation
''';
}

/// Writes the script for one task and hands back the file name `--script`
/// takes.
///
/// A function rather than a class so a test can hand the controller a writer
/// that touches no disk at all — the real one writes into the user's own
/// `~/.hermes`, which no test may go near.
typedef TaskScriptWriter =
    String Function({
      required String name,
      required TaskRunner runner,
      required String prompt,
      required String workdir,
    });

/// The writer the app uses: builds the script and puts it where Hermes looks.
final taskScriptWriterProvider = Provider<TaskScriptWriter>(
  (ref) =>
      ({
        required String name,
        required TaskRunner runner,
        required String prompt,
        required String workdir,
      }) => writeTaskScript(
        name: name,
        script: taskRunnerScript(
          runner: runner,
          prompt: prompt,
          workdir: workdir,
          // The folders this computer actually has them in, not a guess: the
          // scheduler is a daemon, and a PATH written from the app's own idea
          // of where things live is how `claude: command not found` becomes a
          // task that fails every morning at 8.
          pathDirs: [
            for (final exe in [runner.agent.id, 'node']) ?_binDirOf(exe),
            GridPaths.binDir.path,
          ],
        ),
      ),
);

/// The folder [executable] is in, as this app resolves it, or null when the
/// machine hasn't got it.
String? _binDirOf(String executable) {
  final path = HostEnvironment.findExecutable(executable);
  return path == null ? null : File(path).parent.path;
}

/// Writes [script] where the scheduler can run it, and hands back the file name
/// `--script` takes.
///
/// Executable, because Hermes runs a `.sh` through bash but the file being
/// runnable on its own is what lets the user try it in a terminal — which is
/// the first thing anyone does to a task that isn't working.
String writeTaskScript({
  required String name,
  required String script,
  Directory? into,
}) {
  final dir = into ?? taskScriptsDir;
  dir.createSync(recursive: true);
  final fileName = taskScriptName(name);
  final file = File('${dir.path}/$fileName')..writeAsStringSync(script);
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', file.path]);
  }
  return fileName;
}
