import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/grid_serve_skill.dart';
import '../../features/agents/logic/grid_web_skill.dart';

/// The scripts Grid's guides tell an agent to run, kept in Grid's own home.
///
/// **Why they moved.** They used to live inside the skill folder the app wrote
/// into `~/.claude/skills/grid-web/scripts` and `~/.codex/skills/grid-serve/…`
/// — the user's directories, read by every terminal session they open. The
/// cards themselves are MCP guides now, so the last thing keeping Grid inside
/// those folders was the code beside them.
///
/// `~/.grid` is the app's own directory, which the user installed on purpose;
/// putting them there means an agent's home holds nothing of ours at all.
///
/// One folder, not one per skill: the guides name every script by absolute
/// path, so their layout is an implementation detail of this file and nothing
/// downstream has to agree with it.
Directory gridAgentScriptsDir() =>
    Directory('${GridPaths.home.path}/app/agent-scripts');

/// The scripts by file name, and what goes in them.
///
/// Verbatim the same source the cards shipped: the guides that name them are
/// the same words too, so an agent that used to read a card and one that reads a
/// guide are running exactly the same thing.
Map<String, String> gridAgentScripts() => const {
  'search.py': kGridWebSearchScript,
  'read.py': kGridWebReadScript,
  'browse.py': kGridWebBrowseScript,
  'serve.py': kGridServeScript,
};

/// Writes them, skipping any that already match.
///
/// Rewritten when the content differs rather than every launch, for the reason
/// the installer checks the same thing: the file's modification time is
/// something a person may be reading, and a build that rewrites an identical
/// file makes "when did this change?" unanswerable.
///
/// Failures are swallowed on purpose and reported through [log]: a machine that
/// cannot write here still has an app, and the guides that name these paths say
/// what to do when the script is missing.
/// [into] overrides the destination so a test never writes into the real
/// `~/.grid` — the same escape hatch every store in this app takes.
Future<void> ensureGridAgentScripts({
  Directory? into,
  void Function(String message)? log,
}) async {
  final dir = into ?? gridAgentScriptsDir();
  try {
    await dir.create(recursive: true);
    for (final entry in gridAgentScripts().entries) {
      final file = File('${dir.path}/${entry.key}');
      if (await file.exists() && await file.readAsString() == entry.value) {
        continue;
      }
      await file.writeAsString(entry.value, flush: true);
    }
  } on FileSystemException catch (error) {
    log?.call('agent scripts: ${error.message} (${dir.path})');
  }
}

/// The absolute path of one of them, for a guide to name.
String gridAgentScriptPath(String name) =>
    '${gridAgentScriptsDir().path}/$name';
