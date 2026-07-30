/// Who a skill came from — the store's two folders, as the list understands
/// them.
enum SkillOwner {
  /// Written by the user in the app (`~/.grid/skills/user`).
  user,

  /// Shipped by Grid (`~/.grid/skills/public`) — rewritten by every install, so
  /// an edit here wouldn't survive.
  public;

  /// What the Author column says. "You" for your own, the folder's own name for
  /// the rest — the same word the store uses, so what's on screen and what's on
  /// disk can't drift.
  String get label => this == SkillOwner.user ? 'You' : 'public';
}

/// One thing the assistant knows how to do beyond talking — the agents call
/// these "skills"; on disk a skill is a folder with a `SKILL.md`: a little
/// front-matter card (name + description) telling the agent when to reach for
/// it, plus whatever script it runs.
///
/// Cross-agent vocabulary: every agent's skills plane lists these, whichever
/// folder its skills really live in.
class AgentSkill {
  const AgentSkill({
    required this.name,
    required this.description,
    required this.path,
    required this.owner,
    required this.updatedAt,
  });

  final String name;

  /// One line: what it does. Empty when the skill's card doesn't say.
  final String description;

  /// The skill's folder, shown so a user can find (or delete) it.
  final String path;

  final SkillOwner owner;

  /// When the card was last written — the `SKILL.md` file's own timestamp, so a
  /// skill edited by hand outside the app still reports the truth.
  final DateTime updatedAt;

  /// True when the user wrote this skill in the app. Only these round-trip
  /// through the editor safely — editing a public skill would be undone by the
  /// next install.
  bool get isMine => owner == SkillOwner.user;

  bool get isPublic => owner == SkillOwner.public;
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
