import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/chat/logic/commands/chat_goal.dart';

ChatGoal _goal({
  required GoalStatus status,
  AgentTool? agent,
  DateTime? startedAt,
}) => ChatGoal(
  condition: 'spend the next 8 hours improving the orchestration patterns',
  status: status,
  startedAt: startedAt ?? DateTime(2026, 8, 18, 21),
  agent: agent,
);

void main() {
  group('a goal that would take hold of the next message', () {
    test('is the running one and the stalled one — the two the app has to '
        'stand down when it reopens', () {
      expect(_goal(status: GoalStatus.active).takesTheNextTurn, isTrue);
      expect(_goal(status: GoalStatus.stalled).takesTheNextTurn, isTrue);
    });

    test('is not one that has already ended, or the app would keep clearing '
        'goals it had finished with', () {
      for (final status in [
        GoalStatus.met,
        GoalStatus.impossible,
        GoalStatus.blocked,
        GoalStatus.usageLimited,
        GoalStatus.budgetLimited,
        GoalStatus.dormant,
      ]) {
        expect(
          _goal(status: status).takesTheNextTurn,
          isFalse,
          reason: status.name,
        );
      }
    });
  });

  group('a goal older than its run', () {
    test(
      'is over: twelve hours after it was set, `git pull` typed into that '
      'chat is a command, not the next round of an overnight instruction',
      () {
        final goal = _goal(
          status: GoalStatus.active,
          startedAt: DateTime(2026, 8, 18, 21),
        );

        expect(goal.hasOutlivedItsRun(DateTime(2026, 8, 19, 9, 30)), isTrue);
      },
    );

    test('is not cut short inside the sitting it was set in — a Grid turn runs '
        '40 minutes and a night of them is the point of the feature', () {
      final goal = _goal(
        status: GoalStatus.active,
        startedAt: DateTime(2026, 8, 18, 21),
      );

      expect(goal.hasOutlivedItsRun(DateTime(2026, 8, 19, 4)), isFalse);
    });
  });

  group('reading a goal back off disk', () {
    ChatGoal? read(Map<String, Object?> raw) => ChatGoal.fromJson({
      'condition': 'ship it',
      'startedAt': '2026-08-18T21:00:00.000',
      ...raw,
    });

    test('an app-driven goal saved running comes back handed over, because the '
        'loop that was advancing it died with the process', () {
      expect(read({'status': 'active'})?.status, GoalStatus.dormant);
      expect(
        read({'status': 'active', 'agent': 'hermes'})?.status,
        GoalStatus.dormant,
      );
    });

    test("a delegated goal keeps its status: it lives in the agent's session, "
        'and only telling that agent can end it', () {
      expect(
        read({'status': 'active', 'agent': 'claude'})?.status,
        GoalStatus.active,
      );
    });

    test('a goal saved from the build that had Hold reads as handed back, not '
        'as paused — nothing has resumed a paused goal since 2026-08-18', () {
      expect(read({'status': 'paused'})?.status, GoalStatus.dormant);
    });

    test('every other ending is read as it was written', () {
      expect(read({'status': 'met'})?.status, GoalStatus.met);
      expect(read({'status': 'blocked'})?.status, GoalStatus.blocked);
    });
  });

  group('what the user is told', () {
    test('names the ending and what to do about it — this is the one ending '
        'nobody asked for', () {
      final label = goalBarLabel(
        _goal(status: GoalStatus.dormant),
        DateTime(2026, 8, 19, 9),
      );

      expect(label, contains('will not take your next message'));
      expect(label, contains('Set it again'));
      expect(label, contains('orchestration patterns'));
    });
  });
}
