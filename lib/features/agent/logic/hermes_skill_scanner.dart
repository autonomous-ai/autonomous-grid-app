import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_skill.dart';

/// Finds the skills in the app's own store (`~/.grid/skills`), walking it for
/// `SKILL.md` files. Pure filesystem reads — nothing is written here, so opening
/// the Skills screen can never break a working agent.
///
/// The store is the whole list on purpose. An agent's own folder is its
/// business — Hermes ships ~70 skills of its own and installs more behind the
/// app's back — and mixing those in made a screen the user couldn't recognise
/// their own work in. What the app shows is what the app manages: the user's
/// skills and the public ones Grid installs, both projected into the agent via
/// `skills.external_dirs`.
class AgentSkillScanner {
  AgentSkillScanner({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory get root => Directory(gridSkillsStore(_home));

  /// Every skill in the store, the user's own first, then most recently changed
  /// — the two questions the list is actually asked. Name breaks a tie so a
  /// refresh can't shuffle rows around under the pointer.
  Future<List<AgentSkill>> scan() async {
    final skills = <AgentSkill>[];
    final store = root;
    if (store.existsSync()) {
      await for (final entity in store.list(
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
            owner: _ownerOf(dir.path),
            updatedAt: (await entity.stat()).modified,
          ),
        );
      }
    }
    skills.sort((a, b) {
      if (a.isMine != b.isMine) return a.isMine ? -1 : 1;
      final byDate = b.updatedAt.compareTo(a.updatedAt);
      if (byDate != 0) return byDate;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return skills;
  }

  /// Read off the folder the skill sits in. Only `public/` is Grid's; anything
  /// else in the store is the user's, including a skill they dropped in by hand
  /// or one written by an older version of the app — treating those as public
  /// would quietly deny them the edit button.
  SkillOwner _ownerOf(String path) {
    final prefix = '${root.path}/';
    if (!path.startsWith(prefix)) return SkillOwner.user;
    return path.substring(prefix.length).split('/').first == kPublicSkillsDir
        ? SkillOwner.public
        : SkillOwner.user;
  }
}

/// Overridable so tests point at a temp home and never read the real folders.
final agentSkillScannerProvider = Provider<AgentSkillScanner>(
  (ref) => AgentSkillScanner(),
);
