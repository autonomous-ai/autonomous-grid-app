import 'dart:convert';

/// A skill the assistant has drafted out of the conversation, waiting for the
/// user to say yes.
///
/// The app writes the file, not the agent. Two reasons, and both matter: a skill
/// the agent wrote into a folder would show up in the Skills screen as the
/// agent's own work rather than the user's, and two of the three agents can be
/// running read-only — the one asked to draft a skill must not have to be the
/// one allowed to write it.
class SkillProposal {
  const SkillProposal({
    required this.name,
    required this.description,
    required this.instructions,
  });

  /// What it will be called, and what the folder is named after.
  final String name;

  /// The line the agent later reads to decide whether the skill is relevant —
  /// it does real work, so an empty one is not a proposal.
  final String description;

  /// The body of the card: what to do, in the agent's own words.
  final String instructions;

  /// The proposal in [reply], or null when there isn't one.
  ///
  /// Reads the **last** ```skill block: a reply that revises its own draft ends
  /// with the version it means.
  static SkillProposal? parse(String reply) {
    final blocks = _skillFence.allMatches(reply);
    if (blocks.isEmpty) return null;
    return _fromJson(blocks.last.group(1) ?? '');
  }

  static SkillProposal? _fromJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final name = '${decoded['name'] ?? ''}'.trim();
    final description = '${decoded['description'] ?? ''}'.trim();
    final instructions = '${decoded['instructions'] ?? ''}'.trim();
    // All three or nothing: a skill with no instructions is a name, and one
    // with no description never fires.
    if (name.isEmpty || description.isEmpty || instructions.isEmpty) {
      return null;
    }
    return SkillProposal(
      name: name,
      description: description,
      instructions: instructions,
    );
  }
}

final _skillFence = RegExp(r'```skill\s*\n(.*?)```', dotAll: true);

/// What the app sends when the user asks to turn a conversation into a skill.
///
/// Carries the format inline rather than relying on an installed skill: this is
/// a one-off request the app makes on the user's behalf, and it should work on a
/// fresh machine where nothing has been provisioned yet.
const String kSkillFromChatPrompt = '''
Turn what we just did in this conversation into a reusable skill.

Write it as a single fenced block exactly like this, and nothing after it:

```skill
{
  "name": "File an expense",
  "description": "Use when the user wants to file an expense report. Covers finding the receipt, filling the form and submitting it.",
  "instructions": "Step-by-step instructions here, in the second person, as you would want to read them next time."
}
```

Rules:
- `description` is what you will read later to decide whether this skill applies,
  so it must name the situation, not the steps. It does the real work.
- `instructions` is the body of the card: the steps, the gotchas we hit, and the
  exact commands or paths that mattered. Write what you wish you had been told
  at the start of this conversation.
- Generalise: this runs again on a different day with different specifics. Keep
  what repeats, drop what was only true this time.
- No secrets, tokens or one-off file paths from my machine.
- If there is nothing here worth keeping, say so plainly instead of writing a
  block.
''';
