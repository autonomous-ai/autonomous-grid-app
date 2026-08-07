import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';

void main() {
  group('what the surface calls each scope', () {
    test('every scope has a label short enough for the toolbar button', () {
      for (final scope in const <ReviewScope>[
        LastTurnChanges(),
        UncommittedChanges(),
        UnstagedChanges(),
        StagedChanges(),
        BranchAgainst('origin/main'),
      ]) {
        expect(scope.label, isNotEmpty);
        expect(scope.label.length, lessThanOrEqualTo(24));
      }
    });

    test(
      'a commit is labelled by its short hash, which is what people quote',
      () {
        const commit = CommitRef(
          sha: '0123456789abcdef',
          subject: 'Fix the thing',
          author: 'Dev',
          when: '2 hours ago',
        );

        expect(const CommittedChange(commit).label, '0123456');
      },
    );

    test("an empty list says nothing of *what* — a branch comparison names the "
        'branch, the staged list names the tick', () {
      expect(
        const BranchAgainst('origin/main').emptyLine,
        contains('origin/main'),
      );
      expect(const StagedChanges().emptyLine, contains('ticked'));
    });

    test('ticking files on and off is only offered where an index still '
        'exists — never inside a commit or on a branch', () {
      expect(const UncommittedChanges().canStage, isTrue);
      expect(const UnstagedChanges().canStage, isTrue);
      expect(const BranchAgainst('main').canStage, isFalse);
      expect(
        const CommittedChange(
          CommitRef(sha: 'a', subject: 's', author: 'a', when: 'now'),
        ).canStage,
        isFalse,
      );
    });

    test('untracked files belong to what is not committed, not to the index, '
        'a commit or a branch', () {
      expect(const UncommittedChanges().showsUntracked, isTrue);
      expect(const UnstagedChanges().showsUntracked, isTrue);
      expect(const StagedChanges().showsUntracked, isFalse);
      expect(const BranchAgainst('main').showsUntracked, isFalse);
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

    test('each scope points the agent at its own range, not at a diff the '
        'screen is not showing', () {
      expect(askAgentPrompt(const StagedChanges()), contains('--cached'));
      expect(askAgentPrompt(const UnstagedChanges()), contains('git diff'));
      expect(
        askAgentPrompt(
          const CommittedChange(
            CommitRef(
              sha: '0123456789',
              subject: 'Fix',
              author: 'Dev',
              when: 'now',
            ),
          ),
        ),
        contains('git show 0123456'),
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
