import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../shared/skills/agent_skill_home.dart';
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
/// Everything lands in the agent-neutral store (`~/.grid/skills`), so the
/// user's work belongs to no one agent: new skills under [kUserSkillsDir],
/// which is also what marks them as theirs — [kPublicSkillsDir] is Grid's and
/// gets rewritten by every install.
class SkillAuthor implements SkillWriter {
  SkillAuthor({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  String get _root => gridSkillsStore(_home);

  /// Where a *new* skill of this slug goes — always the user's folder.
  Directory dirFor(String slug) => Directory('$_root/$kUserSkillsDir/$slug');

  /// True when a skill of this name is already there — anywhere in the store,
  /// not just the user's folder. The dialog checks first rather than silently
  /// overwriting someone's work, and a new skill shadowing a public one would
  /// leave the agent reading two skills with one name.
  @override
  bool exists(String name) {
    final slug = skillSlug(name);
    if (slug.isEmpty) return false;
    final root = Directory(_root);
    if (!root.existsSync()) return false;
    return root
        .listSync()
        .whereType<Directory>()
        .any((folder) => Directory('${folder.path}/$slug').existsSync());
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

  /// Rewrite a skill in the folder it already lives in — editing must never
  /// silently move one. When the name changes the folder moves with it and the
  /// old one is removed; otherwise a rename would leave a stale duplicate the
  /// agent would still read.
  @override
  Future<Directory> edit({
    required String previousPath,
    required String name,
    required String description,
    required String instructions,
  }) async {
    _guard(previousPath, 'edit');
    final previous = Directory(previousPath);
    final target = Directory('${previous.parent.path}/${skillSlug(name)}');
    final dir = await _write(target, name, description, instructions);
    if (target.path != previous.path && previous.existsSync()) {
      await previous.delete(recursive: true);
    }
    return dir;
  }

  /// Delete a skill's folder. Guards against a path outside the store, so a bad
  /// `path` can never take out something it shouldn't.
  @override
  Future<void> delete(String path) async {
    _guard(path, 'delete');
    final dir = Directory(path);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// Every write is scoped to the store. A skill the app doesn't own — one
  /// still sitting in an agent's own folder, say — is not ours to rewrite or
  /// remove, and a path that isn't a skill at all must never reach `delete`.
  void _guard(String path, String action) {
    if (!path.startsWith('$_root/')) {
      throw ArgumentError('Refusing to $action outside $_root: $path');
    }
  }
}

/// Overridable so tests write into a temp home, never the real `~/.hermes`.
final skillAuthorProvider = Provider<SkillAuthor>((ref) => SkillAuthor());
