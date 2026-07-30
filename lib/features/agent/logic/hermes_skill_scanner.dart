import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_skill.dart';

/// Finds the skills in one [SkillSource], walking its folder for `SKILL.md`
/// files. Pure filesystem reads — nothing is written here, so opening the
/// Skills screen can never break a working agent.
///
/// One source at a time, rather than every skill on the machine in one list.
/// The three folders answer different questions — "what did I write", "what
/// does Hermes already know", "what does Codex" — and merging them made a
/// screen where the user couldn't find their own two skills among Hermes's
/// seventy.
class AgentSkillScanner {
  AgentSkillScanner({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory rootOf(SkillSource source) => source.root(_home);

  /// Every skill in [source], the user's own first, then most recently changed
  /// — the two questions the list is actually asked. Name breaks a tie so a
  /// refresh can't shuffle rows around under the pointer.
  Future<List<AgentSkill>> scan(SkillSource source) async {
    final skills = <AgentSkill>[];
    final root = rootOf(source);
    // Read once per scan, not once per skill: an agent's folder holds seventy
    // of them and the answer is the same for all.
    final library = source == SkillSource.store
        ? const <String, SkillOwner>{}
        : await _libraryAuthors();
    if (root.existsSync()) {
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
            owner: _ownerOf(source, root, dir.path, library),
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

  /// An agent's own folder is entirely that agent's. Only the app's store is
  /// split, and there only `public/` is Grid's: anything else in it is the
  /// user's, including a skill they dropped in by hand or one written by an
  /// older version of the app — calling those public would quietly deny them
  /// the edit button.
  SkillOwner _ownerOf(
    SkillSource source,
    Directory root,
    String path,
    Map<String, SkillOwner> library,
  ) {
    if (source == SkillSource.store) {
      final prefix = '${root.path}/';
      if (!path.startsWith(prefix)) return SkillOwner.user;
      final folder = path.substring(prefix.length).split('/').first;
      return folder == kPublicSkillsDir ? SkillOwner.public : SkillOwner.user;
    }
    // In an agent's folder, authorship is a question the folder can't answer —
    // Codex's tree is flat, so a skill the user wrote and one the agent shipped
    // sit side by side under the same kind of name. The library knows, because
    // everything the app writes goes through it first; anything it has never
    // heard of belongs to the agent.
    return library[path.split('/').last] ??
        (source == SkillSource.hermes ? SkillOwner.hermes : SkillOwner.codex);
  }

  /// Who wrote each skill the app knows about, by folder name.
  ///
  /// Only the two folders the app writes: everything else in the library is
  /// somebody's stray directory, not an authorship claim.
  Future<Map<String, SkillOwner>> _libraryAuthors() async {
    final store = SkillSource.store.root(_home);
    final authors = <String, SkillOwner>{};
    for (final folder in const [kUserSkillsDir, kPublicSkillsDir]) {
      final dir = Directory('${store.path}/$folder');
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync().whereType<Directory>()) {
        authors[entry.path.split('/').last] = folder == kPublicSkillsDir
            ? SkillOwner.public
            : SkillOwner.user;
      }
    }
    return authors;
  }
}

/// Overridable so tests point at a temp home and never read the real folders.
final agentSkillScannerProvider = Provider<AgentSkillScanner>(
  (ref) => AgentSkillScanner(),
);
