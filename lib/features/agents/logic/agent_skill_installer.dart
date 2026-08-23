import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_config_file.dart';
import '../../../core/agent_homes.dart';
import '../../../shared/skills/agent_skill_home.dart';
import 'agent_catalog.dart';
import 'grid_ask_skill.dart';
import 'grid_chart_skill.dart';
import 'grid_host_skill.dart';
import 'grid_loop_skill.dart';
import 'grid_research_skill.dart';
import 'grid_schedule_skill.dart';
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

  /// The agents this skill is installed for — all four today, though the field
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
  // The method behind a researched answer. `grid-web` gave every agent the
  // tools; on its own an agent still does one search, one page, one confident
  // paragraph — which is how a wrong answer gets written in a trustworthy
  // voice.
  BuiltinGridSkill(
    name: kGridResearchSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridResearchSkillFiles,
  ),
  // The chat can draw a chart from a fenced block, and no agent would ever emit
  // one unless something told it the block exists — a capability nobody knows
  // about is a capability that never fires.
  BuiltinGridSkill(
    name: kGridChartSkillName,
    agents: const {AgentTool.hermes},
    build: gridChartSkillFiles,
  ),
  // Starting a dev server is the same job for every agent, and each runs its
  // commands in a session the runner tears down at the end of a tool call — so
  // each needs the supervisor route or it reports a dead server as running.
  BuiltinGridSkill(
    name: kGridServeSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridServeSkillFiles,
  ),
  // A self-paced `/loop` asks the assistant that just ran the check when to run
  // it again — and, for the first time, lets it say the job is finished. Same
  // fenced-block trick as the chart, and the same reason for a card: nothing
  // else tells an agent the block is read.
  BuiltinGridSkill(
    name: kGridLoopSkillName,
    agents: const {AgentTool.hermes},
    build: gridLoopSkillFiles,
  ),
  // The three jobs the app owns — repeat, goal, schedule — and how to ask for
  // one. Its own card rather than a section of `grid-loop`: a skill is fetched
  // on its name, and `grid-loop` stayed shut for a goal that read exactly like
  // the loop beside it.
  BuiltinGridSkill(
    name: kGridAskSkillName,
    agents: const {AgentTool.hermes},
    build: gridAskSkillFiles,
  ),
  // Every agent reaches for its own timer when asked to repeat something, and
  // every one of those dies with the turn that created it — a job reported as
  // scheduled for a week that is gone in seconds. This is where the machine's
  // real scheduler is, so the answer stops depending on which agent replied.
  BuiltinGridSkill(
    name: kGridScheduleSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex, AgentTool.claude},
    build: gridScheduleSkillFiles,
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
  /// **A skill whose card or scripts differ from this build is overwritten.**
  /// Grid owns these folders, so what is in them has to be what this build
  /// ships: for ten days `grid-serve`, `grid-host` and `grid-web` sat on disk
  /// with front-matter Codex rejects — dropping all three from the skill list it
  /// shows the model — and a fixed build could not have reached a single machine
  /// that already had them, because this checked only whether the folder
  /// existed.
  ///
  /// It compares contents rather than rewriting blindly, which is what the old
  /// existence check was protecting: this runs on every launch and again before
  /// chats, and writing each time moved every card's timestamp — the "Last
  /// updated" the Skills screen shows and sorts by — so a skill nobody had
  /// touched in a month read as changed a second ago. An unchanged skill is
  /// still not written.
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
        final files = skill.build(dir);
        if (await _isCurrent(dir, files)) continue;
        await writeSkillFolder(dir, files);
      }
    }
    await _removeRetired(skillHome);
    if (agent == AgentTool.hermes) {
      await _removeSupersededCopies(skillHome.home);
    }
    // Every agent, not just Hermes: the four cards below became MCP tools for
    // whoever can reach the server, and the copies to take back are in the two
    // homes this app must stop writing to.
    await _removeMcpSupersededCards(skillHome.home);
  }

  /// Whether what sits at [dir] is already exactly what this build ships.
  ///
  /// Every file, not just the card: a skill's script is where its behaviour
  /// lives, and a card that still matches while `serve.py` is three builds old
  /// is the same silent staleness one level down.
  Future<bool> _isCurrent(Directory dir, GridSkillFiles skill) async {
    try {
      final card = File('${dir.path}/SKILL.md');
      if (!await card.exists()) return false;
      if (await card.readAsString() != skill.card) return false;
      for (final entry in skill.files.entries) {
        final file = File('${dir.path}/${entry.key}');
        if (!await file.exists()) return false;
        if (await file.readAsString() != entry.value) return false;
      }
      return true;
    } on FileSystemException {
      // Unreadable counts as stale: rewriting is the recovery, and this runs on
      // every launch, where a throw would take the whole install down with it.
      return false;
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
    await _removeRootHermesCopies(home);
  }

  /// The cards Grid wrote into the user's **own** Hermes root before it had a
  /// profile (2026-08-21), swept wherever they are still found.
  ///
  /// Named, never wholesale: only what [kBuiltinGridSkills] and
  /// [kRetiredGridSkills] say Grid has ever installed. `~/.hermes/skills` is the
  /// user's folder and holds their own work; deleting a directory there because
  /// the app happened to stop using it is how you take someone's afternoon.
  Future<void> _removeRootHermesCopies(String home) async {
    final root = '${AgentHomes.hermesRoot(home)}/skills';
    for (final name in [
      for (final skill in kBuiltinGridSkills) skill.name,
      ...kRetiredGridSkills,
    ]) {
      final dir = Directory('$root/$name');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// The cards Claude Code and Codex now get as MCP tools instead, swept out of
  /// the folders they used to be written to.
  ///
  /// Those two read their cards from `~/.claude/skills` and `~/.codex/skills`,
  /// which belong to the user and to every terminal session they open. The four
  /// here are carried by `grid_ask` and `grid_guide` over Grid's own MCP server,
  /// so nothing is lost by taking the files back — and a card left behind would
  /// be read *beside* the tool, teaching a format the app no longer parses.
  ///
  /// The rest stay for now, and it is worth saying why rather than leaving the
  /// gap to be discovered: `grid-web` and `grid-serve` ship scripts that other
  /// things already call by path, `grid-host` names this machine's tools, and
  /// `grid-schedule` drives `hermes cron` directly. Porting those is a rewrite,
  /// not a relocation.
  Future<void> _removeMcpSupersededCards(String home) async {
    for (final folder in ['.claude/skills', '.codex/skills']) {
      for (final name in kMcpSupersededSkills) {
        final dir = Directory('$home/$folder/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
  }
}

/// The cards that became MCP tools on 2026-08-21, by name.
///
/// Kept beside [kRetiredGridSkills] rather than in it: these are not withdrawn,
/// they still install for Hermes, whose folder is Grid's own profile. This list
/// is only about the two homes the app must stop writing to.
const List<String> kMcpSupersededSkills = [
  'grid-ask',
  'grid-loop',
  'grid-delegate',
  'grid-chart',
];

/// Wire through the container so senders get it via `ref.read`, and tests can
/// point it at a temp home.
final agentSkillInstallerProvider = Provider<AgentSkillInstaller>(
  (ref) => AgentSkillInstaller(),
);
