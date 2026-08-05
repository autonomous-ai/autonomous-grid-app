import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/skills/logic/skill_proposal.dart';

void main() {
  group('a skill drafted out of a conversation', () {
    test('is read out of the fenced block, prose around it and all', () {
      final proposal = SkillProposal.parse('''
Here's what I'd keep from this:

```skill
{
  "name": "File an expense",
  "description": "Use when the user wants to file an expense report.",
  "instructions": "Find the receipt, then fill the form."
}
```
''');
      expect(proposal?.name, 'File an expense');
      expect(proposal?.description, startsWith('Use when'));
      expect(proposal?.instructions, 'Find the receipt, then fill the form.');
    });

    test('a reply that revises its own draft means the last block', () {
      final proposal = SkillProposal.parse('''
```skill
{"name": "First", "description": "d", "instructions": "i"}
```
On reflection:
```skill
{"name": "Second", "description": "d", "instructions": "i"}
```
''');
      expect(proposal?.name, 'Second');
    });

    test('an assistant that says there is nothing worth keeping offers '
        'nothing to save', () {
      expect(
        SkillProposal.parse("Nothing here generalises — I wouldn't keep it."),
        isNull,
      );
    });

    test('a half-written draft is no draft: a skill with no description never '
        'fires, and one with no instructions is a name', () {
      expect(
        SkillProposal.parse(
          '```skill\n{"name": "x", "instructions": "i"}\n```',
        ),
        isNull,
      );
      expect(
        SkillProposal.parse(
          '```skill\n{"name": "x", "description": "d", "instructions": " "}\n```',
        ),
        isNull,
      );
    });

    test('a block that is not JSON is passed over rather than throwing', () {
      expect(SkillProposal.parse('```skill\nnot json\n```'), isNull);
    });
  });

  group('what the app asks for', () {
    test('the prompt carries the format, so it works on a machine where '
        'nothing has been provisioned', () {
      expect(kSkillFromChatPrompt, contains('```skill'));
      expect(kSkillFromChatPrompt, contains('"description"'));
    });

    test('it tells the assistant to generalise and to leave secrets out', () {
      expect(kSkillFromChatPrompt.toLowerCase(), contains('generalise'));
      expect(kSkillFromChatPrompt.toLowerCase(), contains('no secrets'));
    });
  });
}
