import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/plugins/logic/agent_skill.dart';

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
  });
}
