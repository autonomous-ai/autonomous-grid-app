import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/agent_catalog.dart';

/// The category folder user-written skills live under, kept apart from an agent's
/// bundled skills and Grid's own so an update can never overwrite them.
///
/// Skills here are the only ones the app authored, so the only ones it offers to
/// edit — see `AgentSkill.isMine`.
const String kMySkillsCategory = 'my-skills';

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

/// Where one agent auto-discovers skills, and how Grid lays one down there.
///
/// Every agent reads a folder of `<name>/SKILL.md` cards and picks each up by its
/// front-matter — they differ only in the root and whether Grid's own skills sit
/// in a `grid/` category. Centralising that here means a skill path is spelled
/// once, not re-typed in every installer, author and scanner — and swapping which
/// agent a skill targets becomes a one-argument change.
class AgentSkillHome {
  AgentSkillHome(this.agent, {String? home})
    : home = home ?? GridPaths.userHome;

  /// The agent whose skill layout this describes.
  final AgentTool agent;

  /// The user's home directory — overridable so tests point at a temp dir and
  /// never touch the real `~/.hermes` / `~/.codex`.
  final String home;

  /// The folder the agent scans for skills.
  Directory get root => switch (agent) {
    AgentTool.hermes => Directory('$home/.hermes/skills'),
    AgentTool.codex => Directory('$home/.codex/skills'),
  };

  /// A Grid-owned skill's folder — the ones the app installs and rewrites.
  ///
  /// Hermes keeps them under a `grid/` category so a reinstall can't clobber a
  /// bundled or user skill; Codex discovers a flat tree, so they sit at the root.
  Directory gridDir(String name) => switch (agent) {
    AgentTool.hermes => Directory('${root.path}/grid/$name'),
    AgentTool.codex => Directory('${root.path}/$name'),
  };

  /// A user-authored skill's folder, kept apart from Grid + bundled skills so
  /// neither an update nor a reinstall can overwrite the user's own work. Codex
  /// has no category tree, so a user skill sits flat beside the Grid ones — its
  /// slug must not collide with a built-in name.
  Directory myDir(String slug) => switch (agent) {
    AgentTool.hermes => Directory('${root.path}/$kMySkillsCategory/$slug'),
    AgentTool.codex => Directory('${root.path}/$slug'),
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
