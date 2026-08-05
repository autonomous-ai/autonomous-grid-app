import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/grid_research_skill.dart';

void main() {
  group('the research skill', () {
    test('drives grid-web\'s scripts as a sibling folder — the installer puts '
        'every builtin in one parent, and a wrong path is a skill that fails '
        'on its first command', () {
      final files = gridResearchSkillFiles(
        Directory('/home/.grid/skills/public/grid-research'),
        uvPath: '/home/.grid/bin/uv',
      );

      expect(
        files.card,
        contains('/home/.grid/skills/public/grid-web/scripts/search.py'),
      );
      expect(
        files.card,
        contains('/home/.grid/skills/public/grid-web/scripts/read.py'),
      );
      // Nothing of its own to write: the discipline is the whole skill.
      expect(files.files, isEmpty);
    });

    test('demands the two things that make an answer checkable: a link on the '
        'claim, and a list of what could not be verified', () {
      final card = gridResearchSkillFiles(
        Directory('/skills/grid-research'),
      ).card;
      expect(card, contains('markdown link'));
      expect(card, contains('Not verified'));
    });
  });
}
