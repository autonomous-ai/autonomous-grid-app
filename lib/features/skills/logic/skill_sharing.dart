import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agent/logic/hermes_skill_scanner.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_skill.dart';

/// Who a skill is being handed to.
/// Only the assistants the Skills screen manages — see [kSkillTabs]. Claude
/// Code has a skills folder and the installer writes into it, but it is not on
/// this screen, so nothing here offers to hand it a skill.
enum ShareTarget {
  hermes('Hermes', [AgentTool.hermes]),
  codex('Codex', [AgentTool.codex]),
  all('all agents', [AgentTool.hermes, AgentTool.codex]);

  const ShareTarget(this.label, this.agents);

  /// What the menu row and the toast call it — "Share to Hermes", "copied to
  /// all agents".
  final String label;

  /// The agents a copy lands with.
  final List<AgentTool> agents;

  /// The same choice as a pill, where it stands alone rather than following the
  /// word "to".
  String get chip => this == ShareTarget.all ? 'All agents' : label;
}

/// The folder an agent reads its own skills from.
SkillSource skillFolderOf(AgentTool agent) => switch (agent) {
  AgentTool.hermes => SkillSource.hermes,
  AgentTool.codex => SkillSource.codex,
  AgentTool.claude => SkillSource.claude,
};

/// Copies a skill from one folder into an agent's own.
///
/// A copy, not a link: the two agents read different roots and neither can be
/// asked to follow one. Which means the copy goes stale the moment the original
/// changes — sharing again is how you catch it up, and that's why an existing
/// copy is overwritten rather than skipped.
///
/// Hermes already reads the store through `skills.external_dirs`, so it usually
/// has the skill without this. Sharing to it anyway is deliberate: it's the fix
/// when that config entry is gone, and it's how a skill survives the store being
/// moved. Codex has no such projection at all — for Codex this is the only way.
class SkillSharer {
  SkillSharer({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  /// Where a skill folder named [slug] lands in [agent]'s own folder.
  Directory destinationFor(String slug, AgentTool agent) =>
      agentSkillCopy(agent, _home, slug);

  Future<void> share(AgentSkill skill, ShareTarget target) =>
      shareFolder(skill.path, target.agents);

  /// Copy the skill folder at [path] to every agent in [agents], overwriting a
  /// copy already there, then record who has it.
  ///
  Future<void> shareFolder(String path, Iterable<AgentTool> agents) async {
    if (agents.isEmpty) return;
    final from = Directory(path);
    if (!from.existsSync()) {
      throw ArgumentError('${path.split('/').last} is no longer on disk.');
    }
    final slug = path.split('/').last;
    for (final agent in agents) {
      await copySkillFolder(from, destinationFor(slug, agent));
    }
  }

  /// Take the copy named [slug] back out of every agent in [agents].
  ///
  /// Deletes whatever is at that path: a copy the agent installed itself under
  /// the same name is the same skill by the only name that matters.
  Future<void> unshareFolder(String slug, Iterable<AgentTool> agents) async {
    for (final agent in agents) {
      final copy = destinationFor(slug, agent);
      if (copy.existsSync()) await copy.delete(recursive: true);
    }
  }
}

/// The folder names an agent already has, whoever put them there.
///
/// Read off the agent's own folder rather than the app's record, because the
/// question the catalog asks — "does Hermes have this?" — is about the agent,
/// not about what we remember doing.
final agentSkillNamesProvider = FutureProvider.autoDispose
    .family<Set<String>, AgentTool>((ref, agent) async {
      final skills = await ref
          .watch(agentSkillScannerProvider)
          .scan(skillFolderOf(agent));
      return {for (final skill in skills) skill.path.split('/').last};
    });

/// Overridable so tests copy into a temp home, never the real agent folders.
final skillSharerProvider = Provider<SkillSharer>((ref) => SkillSharer());
