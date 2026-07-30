import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/agent_catalog.dart';

/// The app's agent-neutral skills store under [home] — `~/.grid/skills`.
///
/// The one place the app reads skills from and writes them to. Spelled once
/// here so the scanner, the author and the installer can't drift apart, and
/// home-relative so tests point at a temp dir.
String gridSkillsStore(String home) => '$home/.grid/skills';

/// The two folders the store splits into.
///
/// Which of them a skill sits under *is* its authorship: [kUserSkillsDir] holds
/// what the user wrote in the app, [kPublicSkillsDir] what Grid ships. That's
/// why the Skills screen can name an author from a path alone, with no manifest
/// to keep in sync — and why an update can never overwrite the user's work.
const String kUserSkillsDir = 'user';

const String kPublicSkillsDir = 'public';

/// The `uv` every Grid skill drives: the grid CLI's pinned copy in `~/.grid/bin`,
/// which both agents can already reach.
///
/// Spelled once here so a skill never depends on a `uv` being on PATH — the GUI's
/// minimal PATH is exactly what broke other tooling before — and so two skills
/// can't disagree about which interpreter they run on.
String gridSkillUvPath() => '${GridPaths.binDir.path}/uv';

/// A skill on disk: the `SKILL.md` card the agent reads to know *when* to reach
/// for it, plus the files it runs when it does.
///
/// [files] is keyed by each file's path *relative to the skill's own folder*
/// (e.g. `scripts/search.py`), so the same skill lays down identically wherever
/// its home puts it.
class GridSkillFiles {
  const GridSkillFiles({required this.card, this.files = const {}});

  /// The `SKILL.md` body — front-matter card plus instructions.
  final String card;

  /// Relative path → contents for every script the skill runs. Empty for a
  /// pure-instructions skill (a card with no executable behind it).
  final Map<String, String> files;
}

/// Where Grid lays its own skills down for one agent.
///
/// Every agent reads a folder of `<name>/SKILL.md` cards and picks each up by
/// its front-matter — they differ only in which folder that is. Centralising
/// that here means a skill path is spelled once, not re-typed in every
/// installer and scanner.
class AgentSkillHome {
  AgentSkillHome(this.agent, {String? home})
    : home = home ?? GridPaths.userHome;

  /// The agent whose skill layout this describes.
  final AgentTool agent;

  /// The user's home directory — overridable so tests point at a temp dir and
  /// never touch the real `~/.grid` / `~/.codex`.
  final String home;

  /// A Grid-owned skill's folder — the ones the app installs and rewrites.
  ///
  /// Hermes reads the shared store through `skills.external_dirs`, so its copies
  /// live in the store's [kPublicSkillsDir] — the same folder the Skills screen
  /// lists, which is what lets a Grid skill show up there at all. Codex has no
  /// such projection yet, so its copies stay in its own flat tree.
  Directory gridDir(String name) => switch (agent) {
    AgentTool.hermes => Directory(
      '${gridSkillsStore(home)}/$kPublicSkillsDir/$name',
    ),
    AgentTool.codex => Directory('$home/.codex/skills/$name'),
  };
}

/// Write (or refresh) a skill into [dir]: wipe it first so a stale file from an
/// old copy can never linger beside the current one, then lay down the card and
/// every file it runs. Idempotent.
///
/// The one primitive every Grid-skill installer shares, so "how a skill folder is
/// written" lives in exactly one place.
Future<void> writeSkillFolder(Directory dir, GridSkillFiles skill) async {
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  await File('${dir.path}/SKILL.md').writeAsString(skill.card);
  for (final entry in skill.files.entries) {
    final file = File('${dir.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
}
