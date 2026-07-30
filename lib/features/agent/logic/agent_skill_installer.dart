import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_catalog.dart';
import 'grid_media_skills.dart';
import 'grid_serve_skill.dart';
import 'grid_web_skill.dart';

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

  /// The agents this skill is installed for. Web search goes to both; the media
  /// skills are Hermes-only today, so an agent that can't use one never sees it.
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
  // The web-search skill both agents get, so "search the news" works the same
  // whichever is answering. Codex has no web search of its own on a grid, and
  // Hermes's native one shares this skill's DuckDuckGo backend.
  BuiltinGridSkill(
    name: kGridWebSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex},
    build: gridWebSkillFiles,
  ),
  // Starting a dev server is the same job for both agents, and both run their
  // commands in a session the runner tears down at the end of a tool call — so
  // both need the supervisor route or they report a dead server as running.
  BuiltinGridSkill(
    name: kGridServeSkillName,
    agents: const {AgentTool.hermes, AgentTool.codex},
    build: gridServeSkillFiles,
  ),
  // Image + video generation through the grid's media API — Hermes-only for now.
  BuiltinGridSkill(
    name: kGridImageSkillName,
    agents: const {AgentTool.hermes},
    build: (_) => gridImageSkillFiles(),
  ),
  BuiltinGridSkill(
    name: kGridVideoSkillName,
    agents: const {AgentTool.hermes},
    build: (_) => gridVideoSkillFiles(),
  ),
];

/// Installs the Grid skills an agent uses in Agent mode into the place that agent
/// auto-discovers them (`~/.hermes/skills/grid` or `~/.codex/skills`).
///
/// Replaces the old per-agent installer pair: one class, keyed on [AgentTool], so
/// a new agent or a new skill is a registry entry rather than a new installer.
/// Idempotent — safe to call every time the app points an agent at a grid.
class AgentSkillInstaller {
  AgentSkillInstaller({String? home}) : _home = home;

  final String? _home;

  /// Write (or refresh) every built-in skill that applies to [agent].
  Future<void> install(AgentTool agent) async {
    final skillHome = AgentSkillHome(agent, home: _home);
    for (final skill in kBuiltinGridSkills.where((s) => s.appliesTo(agent))) {
      final dir = skillHome.gridDir(skill.name);
      await writeSkillFolder(dir, skill.build(dir));
    }
    if (agent == AgentTool.hermes) {
      await _removeLeakedPrototypes(skillHome.home);
    }
  }

  /// The hand-made Grid prototypes baked a live API key into their scripts (and a
  /// `config.env`), living under Hermes's own `creative` category or at the
  /// skills root. Remove them so no credential lingers and the agent never sees
  /// two same-named skills. The `grid/` copies are owned and rewritten by
  /// [install], so they're not touched here.
  Future<void> _removeLeakedPrototypes(String home) async {
    for (final legacy in const [
      '.hermes/skills/creative/grid-image-gen',
      '.hermes/skills/creative/grid-video-gen',
      '.hermes/skills/grid-image-gen',
      '.hermes/skills/grid-video-gen',
    ]) {
      final dir = Directory('$home/$legacy');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// Wire through the container so senders get it via `ref.read`, and tests can
/// point it at a temp home.
final agentSkillInstallerProvider = Provider<AgentSkillInstaller>(
  (ref) => AgentSkillInstaller(),
);
