import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/agent_skill.dart';

/// Finds the skills Hermes reads, walking every root for `SKILL.md` files:
/// the agent-neutral store (`~/.grid/skills`, projected into Hermes via
/// `skills.external_dirs`) and Hermes's own `~/.hermes/skills`. Pure
/// filesystem reads — nothing is written here, so opening the Skills screen
/// can never break a working agent.
class AgentSkillScanner {
  AgentSkillScanner({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  /// The shared store first, then the agent's own folder — same precedence a
  /// reader needs when the two hold a same-named skill: both are shown, and
  /// the paths tell them apart.
  List<Directory> get roots => [
    Directory('$_home/.grid/skills'),
    Directory('$_home/.hermes/skills'),
  ];

  /// Every installed skill, sorted by name so the list is stable between
  /// refreshes.
  Future<List<AgentSkill>> scan() async {
    final skills = <AgentSkill>[];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('/SKILL.md')) continue;
        final dir = entity.parent;
        final card = parseSkillCard(
          await entity.readAsString(),
          fallbackName: dir.path.split('/').last,
        );
        skills.add(
          AgentSkill(
            name: card.name,
            description: card.description,
            path: dir.path,
            fromGrid: dir.path.contains('/skills/grid/'),
          ),
        );
      }
    }
    skills.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return skills;
  }
}

/// Overridable so tests point at a temp home and never read the real folders.
final agentSkillScannerProvider = Provider<AgentSkillScanner>(
  (ref) => AgentSkillScanner(),
);
