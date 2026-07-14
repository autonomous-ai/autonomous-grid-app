import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// The category folder user-written skills live under, kept apart from Hermes's
/// bundled skills and Grid's so an update can never overwrite them.
///
/// Skills here are the only ones the app authored, so the only ones it offers to
/// edit — see [AgentSkill.isMine].
const String kMySkillsCategory = 'my-skills';

/// One thing the assistant knows how to do beyond talking — Hermes calls these
/// "skills"; the app calls them plugins, because that's what they are to a user.
///
/// On disk a skill is a folder with a `SKILL.md`: a little front-matter card
/// (name + description) telling the agent when to reach for it, plus whatever
/// script it runs.
class AgentSkill {
  const AgentSkill({
    required this.name,
    required this.description,
    required this.path,
    required this.fromGrid,
  });

  final String name;

  /// One line: what it does. Empty when the skill's card doesn't say.
  final String description;

  /// The skill's folder, shown so a user can find (or delete) it.
  final String path;

  /// Installed by Grid itself (as opposed to something the user added by hand),
  /// so the UI can say where it came from instead of leaving the user guessing.
  final bool fromGrid;

  /// The folder Hermes files it under ("productivity", "grid", "my-skills"), or
  /// empty for a skill sitting loose at the top. Hermes ships ~70 of them, so the
  /// category is what makes the list readable.
  String get category {
    final after = path.split('/skills/').last;
    final parts = after.split('/');
    return parts.length > 1 ? parts.first : '';
  }

  /// True when the user wrote this skill in the app (it lives under
  /// [kMySkillsCategory]). Only these round-trip through the editor safely —
  /// editing a bundled or Grid skill would be undone by the next update.
  bool get isMine => category == kMySkillsCategory;
}

/// Reads the `name` / `description` out of a `SKILL.md` front-matter card.
///
/// Deliberately forgiving: a hand-written skill may have no card, an unquoted
/// value, or extra keys. Anything we can't read falls back to [fallbackName] and
/// an empty description rather than hiding the skill — it's still installed, and
/// the user should see it.
({String name, String description}) parseSkillCard(
  String markdown, {
  required String fallbackName,
}) {
  var name = '';
  var description = '';
  var inCard = false;

  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line == '---') {
      // The card is the first `---` … `---` block; stop at its end.
      if (inCard) break;
      inCard = true;
      continue;
    }
    if (!inCard) continue;
    final separator = line.indexOf(':');
    if (separator == -1) continue;
    final key = line.substring(0, separator).trim();
    final value = _unquote(line.substring(separator + 1).trim());
    if (key == 'name' && name.isEmpty) name = value;
    if (key == 'description' && description.isEmpty) description = value;
  }

  return (name: name.isEmpty ? fallbackName : name, description: description);
}

String _unquote(String value) {
  if (value.length < 2) return value;
  final first = value[0];
  final last = value[value.length - 1];
  final quoted = (first == '"' && last == '"') || (first == "'" && last == "'");
  return quoted ? value.substring(1, value.length - 1) : value;
}

/// Pulls the instructions back out of a `SKILL.md` — everything below the
/// front-matter card and the `# Heading` the app writes — so the editor can
/// reopen a skill pre-filled instead of forcing the user to rewrite the steps.
String parseSkillInstructions(String markdown) {
  final lines = markdown.split('\n');
  var index = 0;

  // Skip the first `---` … `---` card, if there is one.
  if (index < lines.length && lines[index].trim() == '---') {
    index++;
    while (index < lines.length && lines[index].trim() != '---') {
      index++;
    }
    if (index < lines.length) index++;
  }

  // Drop the blank line and the single `# Heading` the app writes above the body.
  while (index < lines.length && lines[index].trim().isEmpty) {
    index++;
  }
  if (index < lines.length && lines[index].trimLeft().startsWith('# ')) {
    index++;
  }

  return lines.sublist(index).join('\n').trim();
}

/// Finds the skills installed for the agent by walking `~/.hermes/skills` for
/// `SKILL.md` files. Pure filesystem reads — nothing is written here, so opening
/// the Plugins screen can never break a working agent.
class AgentSkillScanner {
  AgentSkillScanner({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory get root => Directory('$_home/.hermes/skills');

  /// Every installed skill, sorted by name so the list is stable between
  /// refreshes.
  Future<List<AgentSkill>> scan() async {
    if (!root.existsSync()) return const [];

    final skills = <AgentSkill>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
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
    skills.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return skills;
  }
}

/// Overridable so tests point at a temp home and never read the real `~/.hermes`.
final agentSkillScannerProvider = Provider<AgentSkillScanner>(
  (ref) => AgentSkillScanner(),
);

/// The plugins installed on this computer. Refresh with `ref.invalidate` after
/// installing one.
final agentSkillsProvider = FutureProvider<List<AgentSkill>>(
  (ref) => ref.watch(agentSkillScannerProvider).scan(),
);
