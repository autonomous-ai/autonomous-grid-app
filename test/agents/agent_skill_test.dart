import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agents/logic/agent_skill.dart';

void main() {
  group('parseSkillCard', () {
    test('reads the name and description out of the front-matter card', () {
      final card = parseSkillCard('''
---
name: grid-image-gen
description: Generate an image through the user's Grid.
tags: [image-generation, grid]
---

# Generate an image
''', fallbackName: 'folder-name');

      expect(card.name, 'grid-image-gen');
      expect(card.description, "Generate an image through the user's Grid.");
    });

    test('unquotes values and ignores keys after the card ends', () {
      final card = parseSkillCard('''
---
name: "quoted"
---

description: not part of the card
''', fallbackName: 'folder-name');

      expect(card.name, 'quoted');
      expect(card.description, isEmpty);
    });

    test('a hand-written skill with no card still shows up, named after its '
        'folder — hiding it would lie about what the agent can do', () {
      final card = parseSkillCard(
        '# Just some notes',
        fallbackName: 'my-skill',
      );

      expect(card.name, 'my-skill');
      expect(card.description, isEmpty);
    });
  });

  group('parseSkillInstructions', () {
    test('reads the steps back, dropping the card and the heading', () {
      const markdown = '''
---
name: weekly-report
description: Use for status updates.
---

# Weekly report

Read the folder.
Write ten lines.''';

      expect(
        parseSkillInstructions(markdown),
        'Read the folder.\nWrite ten lines.',
      );
    });

    test('a hand-written skill with no card still yields its body', () {
      expect(
        parseSkillInstructions('# Notes\n\nJust do the thing.'),
        'Just do the thing.',
      );
    });
  });

  group('AgentSkill.isMine', () {
    test('flags a skill under my-skills as the user\'s own, editable', () {
      const mine = AgentSkill(
        name: 'notes',
        description: '',
        path: '/h/.hermes/skills/$kMySkillsCategory/notes',
        fromGrid: false,
      );
      const bundled = AgentSkill(
        name: 'refactor',
        description: '',
        path: '/h/.hermes/skills/software-development/refactor',
        fromGrid: false,
      );

      expect(mine.isMine, isTrue);
      expect(mine.category, kMySkillsCategory);
      expect(bundled.isMine, isFalse);
    });
  });

  group('AgentSkillScanner', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_skills_test');
    });
    tearDown(() => home.delete(recursive: true));

    Future<void> writeSkill(String path, String markdown) async {
      final dir = Directory('${home.path}/$path');
      await dir.create(recursive: true);
      await File('${dir.path}/SKILL.md').writeAsString(markdown);
    }

    test('reads nothing (rather than throwing) when the agent has no skills '
        'folder', () async {
      expect(await AgentSkillScanner(home: home.path).scan(), isEmpty);
    });

    test(
      'finds every installed skill, sorted, and flags Grid\'s own',
      () async {
        await writeSkill(
          '.hermes/skills/grid/grid-image-gen',
          '---\nname: grid-image-gen\ndescription: Make a picture.\n---\n',
        );
        await writeSkill(
          '.hermes/skills/mine/notes',
          '---\nname: notes\ndescription: Read my notes.\n---\n',
        );

        final skills = await AgentSkillScanner(home: home.path).scan();

        expect(skills.map((s) => s.name).toList(), ['grid-image-gen', 'notes']);
        expect(skills.first.fromGrid, isTrue);
        expect(skills.first.description, 'Make a picture.');
        expect(skills.last.fromGrid, isFalse);
      },
    );

    test(
      'reads the shared store and the agent\'s own folder as one list',
      () async {
        await writeSkill(
          '.grid/skills/my-skills/shared-skill',
          '---\nname: shared-skill\ndescription: Lives in the store.\n---\n',
        );
        await writeSkill(
          '.hermes/skills/my-skills/legacy-skill',
          '---\nname: legacy-skill\ndescription: Written before the store.\n---\n',
        );

        final skills = await AgentSkillScanner(home: home.path).scan();

        expect(skills.map((s) => s.name).toList(), [
          'legacy-skill',
          'shared-skill',
        ]);
        // Both count as the user's own, whichever root they live in.
        expect(skills.every((s) => s.isMine), isTrue);
      },
    );
  });
}
