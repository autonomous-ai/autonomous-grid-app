import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../agents/logic/agent_skill.dart';
import '../../agents/logic/skill_writer.dart';

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

/// Writes skills the user authors in the app.
///
/// New skills go into the agent-neutral store (`~/.grid/skills/my-skills/`),
/// so the user's work belongs to no one agent; skills written before the store
/// existed live on in `~/.hermes/skills/my-skills/` and are edited in place —
/// a migration that moved folders under a running agent would be a way to lose
/// one.
class SkillAuthor implements SkillWriter {
  SkillAuthor({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  String get _sharedRoot => '$_home/.grid/skills';
  String get _legacyRoot => '$_home/.hermes/skills';

  /// Where a *new* skill of this slug goes — always the shared store.
  Directory dirFor(String slug) =>
      Directory('$_sharedRoot/$kMySkillsCategory/$slug');

  Directory _legacyDirFor(String slug) =>
      Directory('$_legacyRoot/$kMySkillsCategory/$slug');

  /// True when a skill of this name is already there — in either root. The
  /// dialog checks first rather than silently overwriting someone's work, and
  /// a shared-store skill shadowing a legacy one would leave the agent reading
  /// two skills with one name.
  @override
  bool exists(String name) {
    final slug = skillSlug(name);
    return dirFor(slug).existsSync() || _legacyDirFor(slug).existsSync();
  }

  /// Create the skill in the shared store and return its folder.
  @override
  Future<Directory> create({
    required String name,
    required String description,
    required String instructions,
  }) => _write(dirFor(skillSlug(name)), name, description, instructions);

  Future<Directory> _write(
    Directory dir,
    String name,
    String description,
    String instructions,
  ) async {
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
  @override
  Future<String> readInstructions(String path) async {
    final markdown = await File('$path/SKILL.md').readAsString();
    return parseSkillInstructions(markdown);
  }

  /// Rewrite one of the user's own skills, in the root it already lives in —
  /// editing must never silently move a skill between stores. When the name
  /// changes the folder moves with it, so the old one is removed — otherwise a
  /// rename would leave a stale duplicate the agent would still read.
  @override
  Future<Directory> edit({
    required String previousSlug,
    required String name,
    required String description,
    required String instructions,
  }) async {
    final legacy = _legacyDirFor(previousSlug).existsSync();
    final target = legacy
        ? _legacyDirFor(skillSlug(name))
        : dirFor(skillSlug(name));
    final dir = await _write(target, name, description, instructions);
    if (skillSlug(name) != previousSlug) {
      final old = legacy ? _legacyDirFor(previousSlug) : dirFor(previousSlug);
      if (old.existsSync()) await old.delete(recursive: true);
    }
    return dir;
  }

  /// Delete a skill's folder. Guards against a path outside both skills trees,
  /// so a bad `path` can never take out something it shouldn't.
  @override
  Future<void> delete(String path) async {
    final inside =
        path.startsWith('$_sharedRoot/') || path.startsWith('$_legacyRoot/');
    if (!inside) {
      throw ArgumentError(
        'Refusing to delete outside the skills folders: $path',
      );
    }
    final dir = Directory(path);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// Overridable so tests write into a temp home, never the real `~/.hermes`.
final skillAuthorProvider = Provider<SkillAuthor>((ref) => SkillAuthor());
