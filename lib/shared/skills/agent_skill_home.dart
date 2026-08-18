import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/agent_catalog.dart';
import '../../infrastructure/cli/host_environment.dart';

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
/// The agent folders are what the screen actually shows, and what an assistant
/// actually reads.
enum SkillSource {
  store('Library'),
  hermes('Hermes'),
  codex('Codex'),
  claude('Claude Code'),
  pi('Pi');

  const SkillSource(this.label);

  /// What the pill above the list says.
  final String label;

  Directory root(String home) => switch (this) {
    SkillSource.store => Directory(gridSkillsStore(home)),
    SkillSource.hermes => Directory('$home/.hermes/skills'),
    SkillSource.codex => Directory('$home/.codex/skills'),
    SkillSource.claude => Directory('$home/.claude/skills'),
    // Pi keeps its skills a level down, under its agent config dir.
    SkillSource.pi => Directory('$home/.pi/agent/skills'),
  };

  /// The agent this folder belongs to, or null for the library.
  AgentTool? get agent => switch (this) {
    SkillSource.store => null,
    SkillSource.hermes => AgentTool.hermes,
    SkillSource.codex => AgentTool.codex,
    SkillSource.claude => AgentTool.claude,
    SkillSource.pi => AgentTool.pi,
  };
}

/// The folders the Skills screen offers, in tab order — every assistant the app
/// can run.
///
/// The one place that decision is made: an agent listed here gets a tab, a
/// share target, and a mark on the rows of the others that also hold its
/// skills. One that isn't gets none of those, however much of it exists
/// elsewhere in the app.
const List<SkillSource> kSkillTabs = [
  SkillSource.hermes,
  SkillSource.codex,
  SkillSource.claude,
  SkillSource.pi,
];

/// The assistants the Skills screen manages — [kSkillTabs] as agents.
///
/// Everything in the feature that loops over agents loops over *this*, not
/// `AgentTool.values`, so an agent the screen doesn't manage never turns up as
/// a mark on a row or a target in a menu.
final List<AgentTool> kSkillAgents = [
  for (final source in kSkillTabs) source.agent!,
];

/// Where a copy of a skill lands in [agent]'s own folder: flat at its root,
/// under the skill's own name.
///
/// Flat for both, and without the library's `user/` / `public/` split, because
/// inside an agent's folder that split would carry no information — authorship
/// is read back off the library by name, so the folder only has to be somewhere
/// the agent looks. One shape also means one place a copy can be: install and
/// a later hand-share write the same path instead of two copies of one skill.
Directory agentSkillCopy(
  AgentTool agent,
  String home,
  String slug,
) => switch (agent) {
  AgentTool.hermes => Directory('${SkillSource.hermes.root(home).path}/$slug'),
  AgentTool.codex => Directory('${SkillSource.codex.root(home).path}/$slug'),
  AgentTool.claude => Directory('${SkillSource.claude.root(home).path}/$slug'),
  AgentTool.pi => Directory('${SkillSource.pi.root(home).path}/$slug'),
};

/// The `uv` every Grid skill drives — the pinned copy in `~/.grid/bin` when it
/// is there, else whichever `uv` this machine already has.
///
/// Spelled once here so two skills can't disagree about which interpreter they
/// run on, and always resolved to an **absolute path**: a card that named a bare
/// `uv` would depend on the child's PATH, and a GUI's minimal PATH is exactly
/// what broke other tooling before.
///
/// **The pinned copy is not always there.** It arrives with `UvToolInstall`,
/// which only runs when Hermes is installed through the app — so a machine
/// running Claude Code, Codex or Pi and no Hermes has no `~/.grid/bin/uv`, and
/// every skill card written for it named a file that does not exist. What the
/// user saw was `grid-web` reaching for the network and dying on
/// `exit code 127 … no such file or directory`, immediately after Claude Code's
/// own `WebSearch` had already failed — two dead ends in a row on a question
/// that had a perfectly good answer.
///
/// [HostEnvironment.findExecutable] is the fallback rather than a second guessed
/// path because it searches the *augmented* PATH, which already leads with
/// `~/.grid/bin` and then `~/.local/bin` (where `uv tool install` puts it). So
/// the pinned copy still wins when it exists, and nothing here has to know the
/// list of places a `uv` can live.
///
/// Falls back to the pinned path when there is no `uv` at all. Naming where it
/// *should* be beats naming nothing: the skill fails either way, and this way
/// the error says which file to go and install.
String gridSkillUvPath() =>
    HostEnvironment.findExecutable('uv') ?? '${GridPaths.binDir.path}/uv';

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

/// Write (or refresh) a skill into [dir]: wipe it first so a stale file from an
/// old copy can never linger beside the current one, then lay down the card and
/// every file it runs. Idempotent.
///
/// The one primitive every Grid-skill installer shares, so "how a skill folder
/// is written" lives in exactly one place. It always writes — deciding whether
/// a folder needs writing at all is the caller's call, and only the installer
/// makes it (see `AgentSkillInstaller.install`).
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
