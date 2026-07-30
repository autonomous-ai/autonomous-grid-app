import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agents/logic/agent_skill.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

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

  group('AgentSkillScanner', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_skills_test');
    });
    tearDown(() => home.delete(recursive: true));

    Future<File> writeSkill(String path, String markdown) async {
      final dir = Directory('${home.path}/$path');
      await dir.create(recursive: true);
      final card = File('${dir.path}/SKILL.md');
      await card.writeAsString(markdown);
      return card;
    }

    test(
      'reads nothing (rather than throwing) when the store is missing',
      () async {
        expect(
          await AgentSkillScanner(home: home.path).scan(SkillSource.store),
          isEmpty,
        );
      },
    );

    test('names the author from the folder a skill sits in', () async {
      await writeSkill(
        '.grid/skills/$kPublicSkillsDir/grid-image-gen',
        '---\nname: grid-image-gen\ndescription: Make a picture.\n---\n',
      );
      await writeSkill(
        '.grid/skills/$kUserSkillsDir/notes',
        '---\nname: notes\ndescription: Read my notes.\n---\n',
      );

      final skills = await AgentSkillScanner(
        home: home.path,
      ).scan(SkillSource.store);

      final byName = {for (final skill in skills) skill.name: skill};
      expect(byName['grid-image-gen']!.owner, SkillOwner.public);
      expect(byName['grid-image-gen']!.description, 'Make a picture.');
      expect(byName['notes']!.owner, SkillOwner.user);
      expect(byName['notes']!.isMine, isTrue);
    });

    test('one source at a time — the store never spills the agents\' own '
        'folders into the list', () async {
      await writeSkill(
        '.hermes/skills/apple/apple-notes',
        '---\nname: apple-notes\ndescription: Bundled with the agent.\n---\n',
      );
      await writeSkill(
        '.codex/skills/review-pr',
        '---\nname: review-pr\ndescription: Codex ships it.\n---\n',
      );
      await writeSkill(
        '.grid/skills/$kUserSkillsDir/notes',
        '---\nname: notes\ndescription: Mine.\n---\n',
      );
      final scanner = AgentSkillScanner(home: home.path);

      expect((await scanner.scan(SkillSource.store)).map((s) => s.name), [
        'notes',
      ]);
      expect((await scanner.scan(SkillSource.hermes)).map((s) => s.name), [
        'apple-notes',
      ]);
      expect((await scanner.scan(SkillSource.codex)).map((s) => s.name), [
        'review-pr',
      ]);
    });

    test("a skill the library has never heard of belongs to the agent whose "
        'folder it sits in', () async {
      await writeSkill(
        '.hermes/skills/my-skills/hand-written',
        '---\nname: hand-written\ndescription: d\n---\n',
      );
      await writeSkill(
        '.codex/skills/review-pr',
        '---\nname: review-pr\ndescription: d\n---\n',
      );
      final scanner = AgentSkillScanner(home: home.path);

      final hermes = await scanner.scan(SkillSource.hermes);
      final codex = await scanner.scan(SkillSource.codex);

      expect(hermes.single.owner, SkillOwner.hermes);
      expect(hermes.single.owner.label, 'hermes');
      expect(hermes.single.isMine, isFalse);
      expect(codex.single.owner, SkillOwner.codex);
      expect(codex.single.owner.label, 'codex');
      expect(codex.single.isMine, isFalse);
    });

    test('a source with no folder reads as empty, not as a crash', () async {
      final scanner = AgentSkillScanner(home: home.path);

      expect(await scanner.scan(SkillSource.hermes), isEmpty);
      expect(await scanner.scan(SkillSource.codex), isEmpty);
    });

    test('anything in the store that is not public counts as the user\'s, so '
        'a hand-dropped skill keeps its edit button', () async {
      await writeSkill(
        '.grid/skills/my-skills/written-by-an-older-build',
        '---\nname: older\ndescription: d\n---\n',
      );

      final skills = await AgentSkillScanner(
        home: home.path,
      ).scan(SkillSource.store);

      expect(skills.single.owner, SkillOwner.user);
    });

    test(
      'the user\'s own come first, then the most recently changed',
      () async {
        final old = await writeSkill(
          '.grid/skills/$kUserSkillsDir/older',
          '---\nname: older\ndescription: d\n---\n',
        );
        await old.setLastModified(DateTime(2026, 7, 1));
        final fresh = await writeSkill(
          '.grid/skills/$kUserSkillsDir/newer',
          '---\nname: newer\ndescription: d\n---\n',
        );
        await fresh.setLastModified(DateTime(2026, 7, 28));
        // Rewritten by the last install, so the newest file on disk by far — it
        // still must not outrank a skill the user wrote.
        final installed = await writeSkill(
          '.grid/skills/$kPublicSkillsDir/grid-web',
          '---\nname: grid-web\ndescription: d\n---\n',
        );
        await installed.setLastModified(DateTime(2026, 7, 30));

        final skills = await AgentSkillScanner(
          home: home.path,
        ).scan(SkillSource.store);

        expect(skills.map((s) => s.name).toList(), [
          'newer',
          'older',
          'grid-web',
        ]);
        expect(skills.first.updatedAt, DateTime(2026, 7, 28));
      },
    );
  });
}
