import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_config_file.dart';
import '../../../shared/skills/agent_skill_home.dart';
import 'agent_catalog.dart';
import 'grid_host_skill.dart';
import 'grid_serve_skill.dart';
import 'grid_web_skill.dart';
import 'adapters/hermes_shared_skills.dart';

/// One skill the app installs for its agents, and which agents get it.
///
/// [build] takes the folder the skill will land in, because a card can name its
/// own scripts by absolute path (see [gridWebSkillFiles]) — so the files are a
/// function of where they're written, not a constant.
class BuiltinGridSkill {
  const BuiltinGridSkill({
    required this.name,
    required this.agents,
    required this.build,
  });

  /// The skill's folder name, e.g. `grid-web`.
  final String name;

  /// The agents this skill is installed for — all three today, though the field
  /// stays because a skill can depend on something only one agent has.
  final Set<AgentTool> agents;

  /// Builds the card + scripts for the folder the skill lands in.
  final GridSkillFiles Function(Directory dir) build;

  bool appliesTo(AgentTool agent) => agents.contains(agent);
}

/// The skills Grid installs into an agent, and who gets each.
///
/// Adding a skill is one entry here; adding an agent is one branch in
/// [AgentSkillHome]. Neither touches the installer below.
final List<BuiltinGridSkill> kBuiltinGridSkills = [
  // The web-search skill every agent gets, so "search the news" works the same
  // whichever is answering. Neither Codex nor Claude Code can reach the web on a
  // grid — their own search tools are served by their vendor's API, which a
  // relay is not — and Hermes's native one shares this skill's DuckDuckGo
  // backend.
  BuiltinGridSkill(
    name: kGridWebSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridWebSkillFiles,
  ),
  // What this machine has, and what to use instead of the GNU tools it doesn't:
  // every agent runs its commands on the same host, and each was burning calls
  // rediscovering that `timeout`/`gh`/`rg` aren't here.
  BuiltinGridSkill(
    name: kGridHostSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridHostSkillFiles,
  ),
  // Starting a dev server is the same job for every agent, and each runs its
  // commands in a session the runner tears down at the end of a tool call — so
  // each needs the supervisor route or it reports a dead server as running.
  BuiltinGridSkill(
    name: kGridServeSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridServeSkillFiles,
  ),
];

/// Skills Grid used to install and has withdrawn — taken off every machine they
/// reached, rather than left behind.
///
/// A skill nothing writes any more is worse than one that was never there: it
/// keeps firing, on instructions no build maintains and against an endpoint
/// nobody is checking, and the Skills screen can't offer to remove it once the
/// library copy that recorded its authorship is gone. So the installer deletes
/// both copies wherever it finds them.
///
/// **A name here must appear in no [BuiltinGridSkill].** Listing a live skill
/// would delete the folder [install] had just written — that exact bug shipped
/// once, and `retires nothing the registry still installs` in
/// `agent_skill_installer_test.dart` is what keeps it from shipping twice.
const List<String> kRetiredGridSkills = [
  // Image and video generation through the grid's media API, dropped 2026-08-03.
  'grid-image-gen',
  'grid-video-gen',
];

/// Installs the Grid skills an agent uses in Agent mode: into the app's library
/// first, then into the agent's own folder (`~/.hermes/skills`,
/// `~/.codex/skills`, `~/.claude/skills`), which is the only place that agent
/// reads.
///
/// Both, not one: the library copy is what the Skills screen reads authorship
/// from — a `grid-` skill in an agent's folder that the library has never heard
/// of would show as the agent's own work. And it is the original a later
/// re-share copies from.
///
/// Replaces the old per-agent installer pair: one class, keyed on [AgentTool], so
/// a new agent or a new skill is a registry entry rather than a new installer.
/// Idempotent — safe to call on every launch, for every agent that is here.
class AgentSkillInstaller {
  AgentSkillInstaller({String? home}) : _home = home;

  final String? _home;

  /// Put every built-in skill that applies to [agent] where that agent reads,
  /// and keep a copy in the library.
  ///
  /// **A skill whose folder is already there is left completely alone.** This
  /// runs on every launch and again before chats, and rewriting each time
  /// churned the disk and moved every card's timestamp — which is what the
  /// Skills screen shows as "Last updated" and sorts by, so a skill nobody had
  /// touched in a month read as changed a second ago.
  ///
  /// The check is the folder's own existence, nothing finer. So a card whose
  /// wording changed in a new build does *not* reach an agent that already has
  /// the skill; only a folder that was deleted is put back.
  Future<void> install(AgentTool agent) async {
    final skillHome = AgentSkillHome(agent, home: _home);
    // An older build pointed Hermes at the app's library; this one doesn't,
    // and has to undo that wherever it lands. Before the writes, so Hermes
    // never has both the entry and the fresh copies at once.
    if (agent == AgentTool.hermes) {
      await unprojectSharedSkillsStore(HermesConfigFile(home: _home));
    }
    for (final skill in kBuiltinGridSkills.where((s) => s.appliesTo(agent))) {
      // Built twice rather than copied: a card names its own scripts by
      // absolute path, so a copied folder would point the agent at the
      // library's scripts and quietly depend on a folder nothing reads.
      for (final dir in [
        skillHome.libraryGridDir(skill.name),
        skillHome.gridDir(skill.name),
      ]) {
        if (await dir.exists()) continue;
        await writeSkillFolder(dir, skill.build(dir));
      }
    }
    await _removeRetired(skillHome);
    if (agent == AgentTool.hermes) {
      await _removeSupersededCopies(skillHome.home);
    }
  }

  /// Take the withdrawn skills off this agent, and out of the library.
  ///
  /// Every agent, not just the one that was given them: a copy could have been
  /// shared by hand from the Skills screen, and a skill Grid no longer ships
  /// should not survive in a folder it was copied into. The library is
  /// agent-neutral, so whichever agent installs first clears it.
  Future<void> _removeRetired(AgentSkillHome skillHome) async {
    for (final name in kRetiredGridSkills) {
      for (final dir in [
        skillHome.libraryGridDir(name),
        skillHome.gridDir(name),
      ]) {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
  }

  /// The hand-made prototypes, which baked a live API key into their scripts
  /// and sat under `creative/` or at the skills root.
  ///
  /// Leaving them would have the agent reading two skills of one name — the
  /// stale one at that.
  ///
  /// Only paths **nothing writes any more** may be listed here. `skills/<name>`
  /// at the root is where [gridDir] puts a copy today, so a live skill named
  /// there is deleted right after [install] wrote it: that shipped once, and
  /// Hermes had no image skill at all for as long as the line was here.
  /// Withdrawing a skill for good goes through [kRetiredGridSkills] instead,
  /// which covers every agent and the library rather than one hardcoded path.
  Future<void> _removeSupersededCopies(String home) async {
    for (final superseded in const [
      // Where install() itself wrote in an earlier build. Nothing rewrites it
      // now, so what's there is stale — and Hermes would read it beside the
      // current copy as a second skill of the same name.
      '.hermes/skills/grid',
      '.hermes/skills/creative/grid-image-gen',
      '.hermes/skills/creative/grid-video-gen',
    ]) {
      final dir = Directory('$home/$superseded');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// Wire through the container so senders get it via `ref.read`, and tests can
/// point it at a temp home.
final agentSkillInstallerProvider = Provider<AgentSkillInstaller>(
  (ref) => AgentSkillInstaller(),
);
