import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/prompts/logic/prompt_slash.dart';
import 'package:grid_app/features/prompts/logic/saved_prompt.dart';

void main() {
  group('slashQuery — deciding when the prompt menu opens', () {
    test('a bare slash opens the menu with an empty query (show all)', () {
      expect(slashQuery('/'), '');
    });

    test('a single slash token is the query the user is narrowing by', () {
      expect(slashQuery('/rep'), 'rep');
    });

    test('plain text is not a command, so the menu stays closed', () {
      expect(slashQuery('hello'), isNull);
      expect(slashQuery(''), isNull);
    });

    test('a space after the slash means a real message, not a command', () {
      // The user has moved on to writing — "/deploy the app" is a sentence.
      expect(slashQuery('/deploy the app'), isNull);
    });
  });

  group('promptNameSlug — a name you can actually type back after /', () {
    test('spaces become dashes, so /tank-1990 stays one command', () {
      // The whole point: "tank 1990" typed as "/tank 1990" closes the menu at
      // the space, so the name has to be a single token to be reachable.
      expect(promptNameSlug('tank 1990'), 'tank-1990');
      expect(slashQuery('/${promptNameSlug('tank 1990')}'), 'tank-1990');
    });

    test('runs of whitespace collapse to a single dash and ends are trimmed', () {
      expect(promptNameSlug('  weekly   report  '), 'weekly-report');
      expect(promptNameSlug('a\tb'), 'a-b');
    });

    test('stray dashes around and between words collapse, not stack up', () {
      expect(promptNameSlug('tank - 1990'), 'tank-1990');
      expect(promptNameSlug('-lead-'), 'lead');
    });

    test('an already-clean name is left exactly as it is', () {
      expect(promptNameSlug('tank-2026'), 'tank-2026');
    });
  });

  group('matchingPrompts — what the menu lists', () {
    final prompts = [
      const SavedPrompt(id: '1', name: 'Weekly report', body: 'a'),
      const SavedPrompt(id: '2', name: 'Standup notes', body: 'b'),
    ];

    test('an empty query lists the whole library', () {
      expect(matchingPrompts(prompts, ''), prompts);
    });

    test('matches by name, case-insensitively, anywhere in the name', () {
      expect(matchingPrompts(prompts, 'REPORT').map((p) => p.id), ['1']);
    });

    test('no match returns an empty list rather than everything', () {
      expect(matchingPrompts(prompts, 'zzz'), isEmpty);
    });
  });
}
