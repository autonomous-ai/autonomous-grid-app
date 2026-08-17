import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_goal.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

final _start = DateTime.utc(2026, 8, 17, 9);

ChatGoal _goal({
  GoalStatus status = GoalStatus.active,
  int turnsEvaluated = 0,
  String? reason,
}) => ChatGoal(
  condition: 'the tests in test/auth pass',
  status: status,
  startedAt: _start,
  turnsEvaluated: turnsEvaluated,
  reason: reason,
);

void main() {
  group('reading the evaluator', () {
    test('a verdict word on its own line, with the reason after it', () {
      final read = parseGoalVerdict('MET\nAll six tests pass.');
      expect(read.verdict, GoalVerdict.met);
      expect(read.reason, 'All six tests pass.');
    });

    test('impossible is carried through with why, since only it explains a '
        'goal that stopped without being met', () {
      final read = parseGoalVerdict(
        'IMPOSSIBLE\nThe file the condition names does not exist.',
      );
      expect(read.verdict, GoalVerdict.impossible);
      expect(read.reason, 'The file the condition names does not exist.');
    });

    test('anything unreadable is NOT_YET — a goal must never be declared met, '
        'or hopeless, because a model wandered off format', () {
      expect(parseGoalVerdict('Well, sort of?').verdict, GoalVerdict.notYet);
      expect(parseGoalVerdict('').verdict, GoalVerdict.notYet);
      expect(
        parseGoalVerdict('the condition is met, I think').verdict,
        GoalVerdict.notYet,
      );
    });

    test('a verdict with no reason still says something, so the bar is never '
        'blank', () {
      expect(parseGoalVerdict('MET').reason, isNotEmpty);
      expect(parseGoalVerdict('NOT_YET').reason, isNotEmpty);
    });
  });

  group('what the evaluator is asked', () {
    test('it is told it cannot check anything itself — otherwise it invents '
        'having run the tests', () {
      final asked = buildGoalEvaluatorMessages(
        condition: 'the tests pass',
        messages: [ChatMessage(role: ChatRole.user, text: 'run them')],
      );
      expect(asked.first['content'], contains('cannot run commands'));
      expect(asked.last['content'], contains('the tests pass'));
      expect(asked.last['content'], contains('User: run them'));
    });
  });

  group('the next turn', () {
    test("carries the condition and the reviewer's reason, which is the one "
        'thing the assistant does not already know', () {
      final prompt = goalContinuationPrompt('tests pass', 'two still fail');
      expect(prompt, contains('tests pass'));
      expect(prompt, contains('two still fail'));
    });
  });

  group('surviving a restart', () {
    test('a goal still running when the app closed comes back stalled, never '
        'active — reopening a chat must not start firing turns at it', () {
      final written = _goal(turnsEvaluated: 4, reason: 'two still fail');
      final read = ChatGoal.fromJson(written.toJson());

      expect(read?.status, GoalStatus.stalled);
      expect(read?.condition, 'the tests in test/auth pass');
      expect(read?.turnsEvaluated, 4);
      expect(read?.reason, 'two still fail');
    });

    test('an ended goal comes back as it ended', () {
      final read = ChatGoal.fromJson(_goal(status: GoalStatus.met).toJson());
      expect(read?.status, GoalStatus.met);
    });

    test('half-written JSON reads as no goal at all', () {
      expect(ChatGoal.fromJson(null), isNull);
      expect(ChatGoal.fromJson({'condition': '  '}), isNull);
      expect(
        ChatGoal.fromJson({'condition': 'x', 'startedAt': 'not a date'}),
        isNull,
      );
    });
  });

  group('what the bar says', () {
    test(
      'each ending reads as itself — "met" must never look like "gave up"',
      () {
        final now = _start.add(const Duration(minutes: 20));
        final met = goalBarLabel(_goal(status: GoalStatus.met), now);
        final impossible = goalBarLabel(
          _goal(status: GoalStatus.impossible, reason: 'no such file'),
          now,
        );
        final stalled = goalBarLabel(_goal(status: GoalStatus.stalled), now);

        expect(met, contains('Goal met'));
        expect(impossible, contains('no such file'));
        expect(stalled, contains('no work done'));
        expect({met, impossible, stalled}, hasLength(3));
      },
    );

    test(
      'while it runs the bar counts the turns judged and the time spent, '
      'because that is what the user is deciding whether to let continue',
      () {
        final label = goalBarLabel(
          _goal(turnsEvaluated: 3, reason: 'two still fail'),
          _start.add(const Duration(minutes: 42)),
        );
        expect(label, contains('42m'));
        expect(label, contains('3 turns judged'));
        expect(label, contains('two still fail'));
      },
    );

    test('hours read as hours once a run is long — a goal has no ceiling, so '
        'the label must survive one that runs all day', () {
      final label = goalBarLabel(
        _goal(),
        _start.add(const Duration(hours: 5, minutes: 7)),
      );
      expect(label, contains('5h 7m'));
    });

    test('asking with no goal set says so plainly', () {
      expect(goalStatusLine(null, _start), 'No goal set.');
    });
  });
}
