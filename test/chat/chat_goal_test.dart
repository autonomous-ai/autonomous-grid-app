import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_goal.dart';
import 'package:grid_app/features/chat/presentation/goal_bar.dart';

void main() {
  final start = DateTime.utc(2026, 8, 5, 9);
  ChatGoal goal({
    GoalStatus status = GoalStatus.active,
    int turnsUsed = 0,
    int maxTurns = 10,
    int maxMinutes = 30,
  }) => ChatGoal(
    objective: 'Get the tests passing',
    status: status,
    startedAt: start,
    maxTurns: maxTurns,
    maxMinutes: maxMinutes,
    turnsUsed: turnsUsed,
  );

  group('knowing when the assistant is finished', () {
    test('the marker on its own line ends the goal', () {
      expect(goalIsComplete('Everything passes now.\n\nGOAL COMPLETE'), isTrue);
      expect(goalIsComplete('  GOAL COMPLETE  '), isTrue);
    });

    test('the marker quoted mid-sentence does not — an assistant explaining '
        'the convention would otherwise end its own goal', () {
      expect(
        goalIsComplete('When done I should reply GOAL COMPLETE, right?'),
        isFalse,
      );
    });

    test('an ordinary reply leaves it running', () {
      expect(goalIsComplete('Fixed two of the four failures.'), isFalse);
    });
  });

  group('advanceGoal', () {
    test('counts the turn and keeps going while there is budget', () {
      final next = advanceGoal(
        goal(),
        reply: 'Fixed one.',
        now: start.add(const Duration(minutes: 2)),
      );
      expect(next.status, GoalStatus.active);
      expect(next.turnsUsed, 1);
    });

    test('the assistant saying so is what ends it, not the app guessing', () {
      final next = advanceGoal(
        goal(),
        reply: 'All green.\nGOAL COMPLETE',
        now: start,
      );
      expect(next.status, GoalStatus.done);
    });

    test('the last allowed turn spends the budget rather than running one '
        'more', () {
      final next = advanceGoal(
        goal(turnsUsed: 9, maxTurns: 10),
        reply: 'Still two failing.',
        now: start,
      );
      expect(next.turnsUsed, 10);
      expect(next.status, GoalStatus.spent);
    });

    test('running past the time budget stops it even with turns to spare', () {
      final next = advanceGoal(
        goal(maxMinutes: 30),
        reply: 'Halfway.',
        now: start.add(const Duration(minutes: 31)),
      );
      expect(next.status, GoalStatus.spent);
    });

    test('a failed turn blocks it and keeps the reason — repeating a failing '
        'turn nine more times is a loop, not persistence', () {
      final next = advanceGoal(
        goal(),
        failure: 'The assistant could not start.',
        now: start,
      );
      expect(next.status, GoalStatus.blocked);
      expect(next.note, 'The assistant could not start.');
    });

    test('a goal that already stopped is left exactly where it was', () {
      final paused = goal(status: GoalStatus.paused, turnsUsed: 3);
      expect(advanceGoal(paused, reply: 'anything', now: start), paused);
    });
  });

  group('what the bar says', () {
    test('each stopped state reads as itself — "met" must never look like '
        '"gave up"', () {
      expect(
        goalBarLabel(goal(status: GoalStatus.done), start),
        contains('Goal met'),
      );
      expect(
        goalBarLabel(goal(status: GoalStatus.spent, turnsUsed: 10), start),
        allOf(contains('Out of budget'), contains('unmet')),
      );
      expect(
        goalBarLabel(goal(status: GoalStatus.paused), start),
        contains('Paused'),
      );
    });

    test('a running goal shows what it is spending', () {
      final label = goalBarLabel(
        goal(turnsUsed: 3),
        start.add(const Duration(minutes: 12)),
      );
      expect(label, contains('3 of 10 turns'));
      expect(label, contains('12 of 30 min'));
    });

    test('a blocked goal leads with the failure, not with the objective', () {
      final blocked = goal(
        status: GoalStatus.blocked,
      ).copyWith(note: 'No grid is selected');
      expect(goalBarLabel(blocked, start), startsWith('Stopped — No grid'));
    });
  });

  group('a goal on disk', () {
    test('round-trips', () {
      final read = ChatGoal.fromJson(goal(turnsUsed: 4).toJson());
      expect(read?.objective, 'Get the tests passing');
      expect(read?.turnsUsed, 4);
      expect(read?.maxTurns, 10);
      expect(read?.startedAt, start);
    });

    test('an unknown status reads as paused — reopening a chat must not start '
        'sending turns on its own', () {
      final read = ChatGoal.fromJson({
        'objective': 'x',
        'startedAt': start.toIso8601String(),
        'status': 'something-else',
      });
      expect(read?.status, GoalStatus.paused);
    });

    test('a goal with nothing in it is no goal at all', () {
      expect(ChatGoal.fromJson({'objective': '   '}), isNull);
      expect(ChatGoal.fromJson('not a map'), isNull);
    });
  });
}
