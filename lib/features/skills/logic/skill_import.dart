import 'dart:io';

import '../../agents/logic/agent_skill.dart';
import 'skill_files.dart';

/// What a folder must be before the app will take it as a skill: a folder with
/// a `SKILL.md` in it whose front-matter card names the skill and says when to
/// use it.
///
/// Returns null when the folder qualifies, otherwise the one line to show the
/// user. Checked before anything is copied — a half-imported skill the agent
/// then reads is worse than a refusal — and again inside the writer, so no
/// caller can skip it.
///
/// The description is not optional here even though the scanner tolerates one
/// without it. A card with no description is a skill the agent never reaches
/// for: Hermes matches on that line to decide relevance, so importing one would
/// quietly install something that can't fire.
String? skillFolderRefusal(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return "That folder isn't there any more.";

  final card = File('$path/$kSkillCardFileName');
  if (!card.existsSync()) {
    return 'A skill folder needs a $kSkillCardFileName in it. '
        '"${path.split('/').last}" has none.';
  }

  final String markdown;
  try {
    markdown = card.readAsStringSync();
  } on Object {
    return "Couldn't read $kSkillCardFileName in that folder.";
  }

  final fields = readSkillCardFields(markdown);
  if (fields.name.isEmpty || fields.description.isEmpty) {
    final missing = [
      if (fields.name.isEmpty) 'name',
      if (fields.description.isEmpty) 'description',
    ].join(' and ');
    return '$kSkillCardFileName must open with a YAML card giving its name and '
        'description — this one is missing its $missing.';
  }
  return null;
}

/// The card's fields exactly as written, with no fallback.
///
/// [parseSkillCard] names a card-less skill after its folder, which is right
/// for *listing* what's installed — hiding a skill the agent can see would lie.
/// It's wrong for *accepting* one: the fallback would let a folder with no card
/// at all pass the check.
({String name, String description}) readSkillCardFields(String markdown) {
  final card = parseSkillCard(markdown, fallbackName: '');
  return (name: card.name, description: card.description);
}
