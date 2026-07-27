import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/common/agent_prompt.dart';

void main() {
  group('withProjectInstructions', () {
    test('prepends the project rules ahead of the prompt so the agent reads '
        'them first', () {
      final result = withProjectInstructions('Fix the bug.', 'Answer in Thai.');
      expect(result, startsWith('Project instructions'));
      expect(result, contains('Answer in Thai.'));
      expect(result, endsWith('Fix the bug.'));
    });

    test('blank or whitespace-only rules leave the prompt untouched', () {
      expect(withProjectInstructions('Hi', null), 'Hi');
      expect(withProjectInstructions('Hi', ''), 'Hi');
      expect(withProjectInstructions('Hi', '   \n  '), 'Hi');
    });

    test('rules are trimmed so stray padding never bloats the turn', () {
      final result = withProjectInstructions('Go', '  Be brief.  ');
      expect(result, contains('Be brief.'));
      expect(result, isNot(contains('  Be brief.  ')));
    });
  });

  group('withPlanPreamble', () {
    test(
      'tells the agent to plan and not act, keeping the request at the end',
      () {
        final result = withPlanPreamble('Delete the temp files.');
        expect(result, startsWith('Planning mode'));
        expect(result.toLowerCase(), contains('do not run'));
        expect(result, endsWith('Delete the temp files.'));
      },
    );
  });
}
