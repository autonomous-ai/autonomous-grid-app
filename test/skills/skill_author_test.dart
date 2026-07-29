import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agents/logic/agent_skill.dart';
import 'package:grid_app/features/skills/logic/skill_author.dart';

void main() {
  group('skillSlug', () {
    test('turns a title into a folder name a filesystem accepts', () {
      expect(skillSlug('Weekly report'), 'weekly-report');
      expect(skillSlug("Tom's  notes!"), 'toms-notes');
      expect(skillSlug('  Trim me  '), 'trim-me');
    });

    test(
      'a title with nothing usable slugs to empty (the dialog blocks it)',
      () {
        expect(skillSlug('!!!'), isEmpty);
      },
    );
  });

  group('skillMarkdown', () {
    test(
      'writes the front-matter card Hermes reads to decide when to use it',
      () {
        final markdown = skillMarkdown(
          name: 'Weekly report',
          description: 'Use when I ask for a status update.',
          instructions: 'Read the folder, then write ten lines.',
        );

        expect(markdown, startsWith('---\n'));
        expect(markdown, contains('name: weekly-report'));
        expect(
          markdown,
          contains('description: Use when I ask for a status update.'),
        );
        expect(markdown, contains('# Weekly report'));
        expect(markdown, contains('Read the folder, then write ten lines.'));
      },
    );
  });

  group('SkillAuthor', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_skill_author_test');
    });
    tearDown(() => home.delete(recursive: true));

    test('saves the skill where the agent finds it, under the user\'s own '
        'category so an update can never overwrite it', () async {
      final author = SkillAuthor(home: home.path);

      final dir = await author.create(
        name: 'Weekly report',
        description: 'Use for status updates.',
        instructions: 'Summarise the week.',
      );

      expect(
        dir.path,
        '${home.path}/.grid/skills/$kMySkillsCategory/weekly-report',
      );
      final markdown = File('${dir.path}/SKILL.md').readAsStringSync();
      expect(markdown, contains('name: weekly-report'));

      // And the scanner — what the Plugins screen lists — picks it straight up.
      final skills = await AgentSkillScanner(home: home.path).scan();
      expect(skills.single.name, 'weekly-report');
      expect(skills.single.category, kMySkillsCategory);
      expect(skills.single.fromGrid, isFalse);
    });

    test('spots a name already taken, so nobody\'s skill is silently '
        'overwritten', () async {
      final author = SkillAuthor(home: home.path);
      expect(author.exists('Weekly report'), isFalse);

      await author.create(
        name: 'Weekly report',
        description: 'd',
        instructions: 'i',
      );

      expect(author.exists('Weekly report'), isTrue);
      // Same slug, different capitalisation — still taken.
      expect(author.exists('weekly REPORT'), isTrue);
    });

    test(
      'reads a skill\'s steps back so the editor can pre-fill them',
      () async {
        final author = SkillAuthor(home: home.path);
        final dir = await author.create(
          name: 'Weekly report',
          description: 'd',
          instructions: 'Read the folder.\nWrite ten lines.',
        );

        expect(
          await author.readInstructions(dir.path),
          'Read the folder.\nWrite ten lines.',
        );
      },
    );

    test(
      'editing in place keeps the one folder and rewrites its card',
      () async {
        final author = SkillAuthor(home: home.path);
        await author.create(
          name: 'Weekly report',
          description: 'old',
          instructions: 'old steps',
        );

        await author.edit(
          previousSlug: 'weekly-report',
          name: 'Weekly report',
          description: 'new',
          instructions: 'new steps',
        );

        final markdown = File(
          '${author.dirFor('weekly-report').path}/SKILL.md',
        ).readAsStringSync();
        expect(markdown, contains('description: new'));
        expect(markdown, contains('new steps'));
        // Still exactly one skill — no stray duplicate left behind.
        expect(await AgentSkillScanner(home: home.path).scan(), hasLength(1));
      },
    );

    test('renaming a skill moves its folder and leaves no duplicate', () async {
      final author = SkillAuthor(home: home.path);
      await author.create(
        name: 'Old name',
        description: 'd',
        instructions: 'i',
      );

      await author.edit(
        previousSlug: 'old-name',
        name: 'New name',
        description: 'd',
        instructions: 'i',
      );

      expect(author.dirFor('old-name').existsSync(), isFalse);
      expect(author.dirFor('new-name').existsSync(), isTrue);
      final skills = await AgentSkillScanner(home: home.path).scan();
      expect(skills.single.name, 'new-name');
    });

    test(
      'deleting a skill removes its folder so the agent stops using it',
      () async {
        final author = SkillAuthor(home: home.path);
        final dir = await author.create(
          name: 'Weekly report',
          description: 'd',
          instructions: 'i',
        );

        await author.delete(dir.path);

        expect(Directory(dir.path).existsSync(), isFalse);
        expect(await AgentSkillScanner(home: home.path).scan(), isEmpty);
      },
    );

    test(
      'editing a legacy skill keeps it in the agent\'s own folder',
      () async {
        final author = SkillAuthor(home: home.path);
        // A skill written before the shared store existed.
        final legacy = Directory(
          '${home.path}/.hermes/skills/$kMySkillsCategory/old-notes',
        );
        await legacy.create(recursive: true);
        await File('${legacy.path}/SKILL.md').writeAsString(
          skillMarkdown(name: 'Old notes', description: 'd', instructions: 'i'),
        );

        final dir = await author.edit(
          previousSlug: 'old-notes',
          name: 'New notes',
          description: 'd',
          instructions: 'i',
        );

        // Edited in place — never silently moved between stores.
        expect(
          dir.path,
          '${home.path}/.hermes/skills/$kMySkillsCategory/new-notes',
        );
        expect(legacy.existsSync(), isFalse);
        expect(
          Directory(
            '${home.path}/.grid/skills/$kMySkillsCategory/new-notes',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('exists sees a legacy skill, so a new one can\'t shadow it', () async {
      final author = SkillAuthor(home: home.path);
      final legacy = Directory(
        '${home.path}/.hermes/skills/$kMySkillsCategory/taken',
      );
      await legacy.create(recursive: true);
      await File('${legacy.path}/SKILL.md').writeAsString('body');

      expect(author.exists('Taken'), isTrue);
    });

    test('refuses to delete anything outside the skills folder', () async {
      final author = SkillAuthor(home: home.path);
      final outside = await Directory.systemTemp.createTemp('grid_outside');
      addTearDown(() => outside.delete(recursive: true));

      await expectLater(author.delete(outside.path), throwsArgumentError);
      expect(outside.existsSync(), isTrue);
    });
  });
}
