import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_base.dart';

void main() {
  group('what the surface calls each comparison', () {
    test('the uncommitted list never claims to be about a branch', () {
      expect(const UncommittedChanges().label, 'Uncommitted changes');
      expect(
        const UncommittedChanges().description,
        contains('not committed yet'),
      );
    });

    test('a branch comparison names the branch it is measured against, and '
        'says out loud that uncommitted work is not in it', () {
      const base = BranchAgainst('origin/main');

      expect(base.label, contains('origin/main'));
      expect(base.description, contains('not committed'));
    });
  });

  group('askAgentPrompt', () {
    test('points the agent at the changes rather than pasting them: a '
        'sixteen-thousand-line diff in a message would blow the context '
        'window and be paid for twice', () {
      final prompt = askAgentPrompt(const UncommittedChanges());

      expect(prompt, contains('git diff HEAD'));
      expect(prompt, contains('Do not edit anything yet'));
    });

    test('asks for the branch comparison with the same three-dot range the '
        'screen is showing, so the agent reviews what the user is reading', () {
      expect(
        askAgentPrompt(const BranchAgainst('origin/main')),
        contains('git diff origin/main...HEAD'),
      );
    });
  });

  test('two comparisons against the same branch are the same comparison — the '
      'controller reloads on a real change, not on every rebuild', () {
    expect(const BranchAgainst('main'), const BranchAgainst('main'));
    expect(const UncommittedChanges(), const UncommittedChanges());
    expect(const BranchAgainst('main') == const BranchAgainst('dev'), isFalse);
  });
}
