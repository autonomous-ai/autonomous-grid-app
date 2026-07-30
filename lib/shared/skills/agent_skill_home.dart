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

/// A folder of skills, wherever it is.
///
/// [store] is the app's own library. No agent reads it — a skill only reaches
/// an assistant as a copy in that assistant's folder — so it is not a tab on
/// the Skills screen; it is where a new skill is kept so the app has an
/// original to copy from, and the record of who authored what.
///
/// The two agent folders are what the screen actually shows, and what an
/// assistant actually reads.
enum SkillSource {
  store('Library'),
  hermes('Hermes'),
  codex('Codex');

  const SkillSource(this.label);

  /// What the pill above the list says.
  final String label;

  Directory root(String home) => switch (this) {
    SkillSource.store => Directory(gridSkillsStore(home)),
    SkillSource.hermes => Directory('$home/.hermes/skills'),
    SkillSource.codex => Directory('$home/.codex/skills'),
  };

  /// The agent this folder belongs to, or null for the library.
  AgentTool? get agent => switch (this) {
    SkillSource.store => null,
    SkillSource.hermes => AgentTool.hermes,
    SkillSource.codex => AgentTool.codex,
  };
}

/// The folders the Skills screen offers, in tab order — the assistants, and
/// only the assistants.
const List<SkillSource> kSkillTabs = [SkillSource.hermes, SkillSource.codex];

/// Where a copy of a skill lands in [agent]'s own folder: flat at its root,
/// under the skill's own name.
///
/// Flat for both, and without the library's `user/` / `public/` split, because
/// inside an agent's folder that split would carry no information — authorship
/// is read back off the library by name, so the folder only has to be somewhere
/// the agent looks. One shape also means one place a copy can be: install and
/// a later hand-share write the same path instead of two copies of one skill.
Directory agentSkillCopy(AgentTool agent, String home, String slug) =>
    Directory('${SkillSource.values.firstWhere((s) => s.agent == agent).root(home).path}/$slug');

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

  /// The library's copy of a Grid-owned skill.
  ///
  /// Written first and kept, even though no agent reads the library: it is what
  /// makes the screen call these skills `public` rather than the agent's own,
  /// and it is the original every later copy is made from.
  Directory libraryGridDir(String name) =>
      Directory('${gridSkillsStore(home)}/$kPublicSkillsDir/$name');

  /// The agent's own copy — the one it actually reads.
  ///
  /// Exactly where Share would put it, so installing and then sharing the same
  /// skill by hand writes the same folder twice instead of leaving two copies
  /// of one skill under different names.
  Directory gridDir(String name) => agentSkillCopy(agent, home, name);
}

/// Write (or refresh) a skill into [dir]: wipe it first so a stale file from an
/// old copy can never linger beside the current one, then lay down the card and
/// every file it runs. Idempotent.
///
/// The one primitive every Grid-skill installer shares, so "how a skill folder is
/// written" lives in exactly one place.
/// Copy a whole skill folder to [to], replacing whatever is there.
///
/// Replacing, not merging: a skill is one unit, and a merge would leave a file
/// the new copy dropped sitting beside the ones it brought — the agent would
/// read a skill that exists in neither place. Same reasoning as
/// [writeSkillFolder]'s wipe-first.
Future<void> copySkillFolder(Directory from, Directory to) async {
  if (await to.exists()) await to.delete(recursive: true);
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(from.path.length + 1);
    if (entity is Directory) {
      await Directory('${to.path}/$relative').create(recursive: true);
    } else if (entity is File) {
      final target = File('${to.path}/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    }
  }
}

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
