/// Who a skill came from — read off the folder it sits in, since that's the
/// only record of it there is.
///
/// Declared in the order the list shows them: the user's own work first, then
/// what Grid gave them, then what the assistant brought itself. That is the
/// order of "how much is this mine", which is the order someone scanning the
/// list is asking in — so [rank] is the index, and moving a value here moves
/// the rows.
enum SkillOwner {
  /// Written by the user in the app (`~/.grid/skills/user`).
  user('You'),

  /// Shipped by Grid (`~/.grid/skills/public`) — rewritten by every install, so
  /// an edit here wouldn't survive.
  public('public'),

  /// Hermes's own (`~/.hermes/skills`), installed and updated by the agent.
  hermes('hermes'),

  /// Codex's own (`~/.codex/skills`).
  codex('codex'),

  /// Claude Code's own (`~/.claude/skills`).
  claude('claude'),

  /// Pi's own (`~/.pi/agent/skills`).
  pi('pi');

  const SkillOwner(this.label);

  /// Where this owner sits in the list. See the note above: it is the
  /// declaration order, named so the sort reads as intent rather than as a
  /// clever use of `index`.
  int get rank => index;

  /// What the Author column says. "You" for the user's own, otherwise the name
  /// of whoever maintains the folder — the same word the folder uses, so what's
  /// on screen and what's on disk can't drift.
  final String label;
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

  /// True when the user wrote this skill in the app — the only skills the app
  /// offers to edit or delete. Everything else on the screen belongs to whoever
  /// installs it, and the next install would undo the change anyway.
  bool get isMine => owner == SkillOwner.user;

  /// Shipped by Grid into the store. Sits beside the user's own — same folder
  /// tree, same buttons — but the next install rewrites it, so an edit here is
  /// borrowed time.
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
