import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_skill.dart';

/// Who a skill is being handed to.
enum ShareTarget {
  hermes('Hermes', [SkillSource.hermes]),
  codex('Codex', [SkillSource.codex]),
  all('all agents', [SkillSource.hermes, SkillSource.codex]);

  const ShareTarget(this.label, this.sources);

  /// What the menu row and the toast call it.
  final String label;

  /// The folders a copy lands in.
  final List<SkillSource> sources;
}

/// Copies a skill out of the app's store into an agent's own folder.
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

  /// Where [skill] lands in [source]'s folder — flat at its root, under the
  /// same folder name it has in the store, so the two stay recognisably the
  /// same skill.
  Directory destinationFor(AgentSkill skill, SkillSource source) => Directory(
    '${source.root(_home).path}/${skill.path.split('/').last}',
  );

  /// Copy [skill] to every folder [target] names. Overwrites a copy already
  /// there.
  Future<void> share(AgentSkill skill, ShareTarget target) async {
    final from = Directory(skill.path);
    if (!from.existsSync()) {
      throw ArgumentError('"${skill.name}" is no longer on disk.');
    }
    for (final source in target.sources) {
      await copySkillFolder(from, destinationFor(skill, source));
    }
  }
}

/// Overridable so tests copy into a temp home, never the real agent folders.
final skillSharerProvider = Provider<SkillSharer>((ref) => SkillSharer());
