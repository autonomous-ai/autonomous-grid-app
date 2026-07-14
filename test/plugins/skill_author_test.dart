import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/plugins/logic/agent_skill.dart';
import 'package:grid_app/features/plugins/logic/skill_author.dart';

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
        '${home.path}/.hermes/skills/$kMySkillsCategory/weekly-report',
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
  });
}
