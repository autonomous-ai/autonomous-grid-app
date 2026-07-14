import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// Where a skill the user writes in the app lands: their own category, kept apart
/// from Hermes's bundled skills and Grid's, so an update can never overwrite it.
const String kMySkillsCategory = 'my-skills';

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
  SkillAuthor({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory dirFor(String slug) =>
      Directory('$_home/.hermes/skills/$kMySkillsCategory/$slug');

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
}

/// Overridable so tests write into a temp home, never the real `~/.hermes`.
final skillAuthorProvider = Provider<SkillAuthor>((ref) => SkillAuthor());
