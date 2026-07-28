import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/skills/agent_skill_home.dart';
import '../../agents/logic/agent_catalog.dart';
import 'agent_skill.dart';

/// A folder name for [title] — lowercase, dashes, nothing a filesystem will
/// argue with. Empty when the title has no usable characters (the dialog blocks
/// that before it gets here).
String skillSlug(String title) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp(r"['’]"), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug;
}

/// The `SKILL.md` a skill *is*: a front-matter card telling the agent when to
/// reach for it, then the instructions telling it what to do.
///
/// Hermes reads the card to decide whether a skill is relevant to a message, so
/// the description carries real weight — it isn't decoration.
String skillMarkdown({
  required String name,
  required String description,
  required String instructions,
}) {
  final slug = skillSlug(name);
  return '---\n'
      'name: $slug\n'
      'description: $description\n'
      '---\n'
      '\n'
      '# $name\n'
      '\n'
      '${instructions.trim()}\n';
}

/// Writes skills the user authors in the app into Hermes's skills folder, where
/// the agent picks them up on its next run.
class SkillAuthor {
  SkillAuthor({String? home})
    : _skillHome = AgentSkillHome(AgentTool.hermes, home: home);

  final AgentSkillHome _skillHome;

  Directory dirFor(String slug) => _skillHome.myDir(slug);

  /// True when a skill of this name is already there — the dialog checks first
  /// rather than silently overwriting someone's work.
  bool exists(String name) => dirFor(skillSlug(name)).existsSync();

  /// Create the skill and return its folder.
  Future<Directory> create({
    required String name,
    required String description,
    required String instructions,
  }) async {
    final dir = dirFor(skillSlug(name));
    await dir.create(recursive: true);
    await File('${dir.path}/SKILL.md').writeAsString(
      skillMarkdown(
        name: name,
        description: description,
        instructions: instructions,
      ),
    );
    return dir;
  }

  /// The instructions currently in a skill, read back from its `SKILL.md` so the
  /// editor can pre-fill them instead of starting blank.
  Future<String> readInstructions(String path) async {
    final markdown = await File('$path/SKILL.md').readAsString();
    return parseSkillInstructions(markdown);
  }

  /// Rewrite one of the user's own skills. When the name changes the folder
  /// moves with it, so the old one is removed — otherwise a rename would leave a
  /// stale duplicate the agent would still read.
  Future<Directory> edit({
    required String previousSlug,
    required String name,
    required String description,
    required String instructions,
  }) async {
    final dir = await create(
      name: name,
      description: description,
      instructions: instructions,
    );
    if (skillSlug(name) != previousSlug) {
      final old = dirFor(previousSlug);
      if (old.existsSync()) await old.delete(recursive: true);
    }
    return dir;
  }

  /// Delete a skill's folder. Guards against a path outside the skills tree, so
  /// a bad `path` can never take out something it shouldn't.
  Future<void> delete(String path) async {
    if (!path.startsWith('${_skillHome.root.path}/')) {
      throw ArgumentError(
        'Refusing to delete outside the skills folder: $path',
      );
    }
    final dir = Directory(path);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Overridable so tests write into a temp home, never the real `~/.hermes`.
final skillAuthorProvider = Provider<SkillAuthor>((ref) => SkillAuthor());
