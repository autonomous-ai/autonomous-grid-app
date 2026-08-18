import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/chat/logic/commands/chat_goal.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

final _start = DateTime.utc(2026, 8, 17, 9);

ChatGoal _goal({
  GoalStatus status = GoalStatus.active,
  int turnsEvaluated = 0,
  String? reason,
  int? endedAfter,
  AgentTool? agent,
}) => ChatGoal(
  condition: 'the tests in test/auth pass',
  status: status,
  startedAt: _start,
  agent: agent,
  turnsEvaluated: turnsEvaluated,
  reason: reason,
  endedAfter: endedAfter,
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
        final stalled = goalBarLabel(
          _goal(status: GoalStatus.stalled, reason: 'you pressed Stop'),
          now,
        );

        expect(met, contains('Goal met'));
        expect(impossible, contains('no such file'));
        // The stalled line used to hardcode "after 3 turns with no work done",
        // which is true of exactly one of the five ways a goal stalls — it told
        // a user who pressed Stop that their assistant had idled for three
        // turns. It carries the recorded reason now, like the other endings.
        expect(stalled, contains('you pressed Stop'));
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
  group('the line above the composer while it runs', () {
    test('it names the condition, and stays short — the long form is what '
        '/goal prints when asked', () {
      final note = goalStatusNote(_goal(turnsEvaluated: 3));
      expect(note, contains('the tests in test/auth pass'));
      expect(note, contains('3 turns'));
      // No evaluator reason: that is the long form, which `/goal` prints when
      // asked.
      expect(note, isNot(contains('two still fail')));
      expect(note.length, lessThan(goalBarLabel(_goal(), _start).length + 20));
    });

    test('a goal nothing has been judged on yet counts nothing', () {
      expect(goalStatusNote(_goal()), isNot(contains('0 turns')));
    });

    test('one judged turn is a turn, not turns', () {
      final note = goalStatusNote(_goal(turnsEvaluated: 1));
      expect(note, contains('1 turn'));
      expect(note, isNot(contains('1 turns')));
    });

    test(
      'it carries no clock — the strip only repaints when the goal changes, '
      'so a time read here froze at 0s for the whole run and read as stuck',
      () {
        final note = goalStatusNote(_goal(turnsEvaluated: 2));
        // No `12s` / `1m 51s` anywhere — matched as a pattern, because the
        // condition itself is full of the letter.
        expect(note, isNot(matches(RegExp(r'\d+\s*[smh]\b'))));
        // It is still right where it is worked out on demand.
        expect(
          goalBarLabel(_goal(), _start.add(const Duration(seconds: 34))),
          contains('34s'),
        );
      },
    );

    test('the emphasis in front of it says something is happening, and says so '
        'differently once it is only being held', () {
      expect(goalStatusLead(_goal()), 'Pursuing goal');
      expect(goalStatusLead(_goal(status: GoalStatus.paused)), 'Goal held');
    });
  });

  group('who drives a goal', () {
    test('the agent decides the owner, so the two can never disagree', () {
      expect(_goal(agent: AgentTool.claude).owner, GoalOwner.claude);
      expect(_goal(agent: AgentTool.codex).owner, GoalOwner.codex);
      expect(_goal(agent: AgentTool.hermes).owner, GoalOwner.app);
      // Written before goals recorded their agent: the app drove it then.
      expect(_goal().owner, GoalOwner.app);
    });

    test('an owner whose driver has not landed is still driven by the app — a '
        'goal nobody advances would sit active forever, having run only the '
        'turn that set it', () {
      // Codex's goals go over `thread/goal/*`, which is not wired yet.
      expect(GoalOwner.codex.hasDriver, isFalse);
      expect(GoalOwner.codex.isAppDriven, isTrue);
    });

    test('Claude Code drives its own goals, so the app judges none of them — '
        'two evaluators on one condition can disagree, and both would send a '
        'turn', () {
      expect(GoalOwner.claude.hasDriver, isTrue);
      expect(GoalOwner.claude.isAppDriven, isFalse);
    });

    test(
      'a goal only stops being the app\'s once something else drives it',
      () {
        for (final owner in GoalOwner.values) {
          expect(owner.isAppDriven, !owner.hasDriver || owner == GoalOwner.app);
        }
      },
    );
  });

  group('where it ended', () {
    test('the anchor survives a restart, so the line stays at the turn it '
        'happened on rather than sliding to the bottom', () {
      final read = ChatGoal.fromJson(
        _goal(status: GoalStatus.met, endedAfter: 4).toJson(),
      );
      expect(read?.endedAfter, 4);
    });

    test('a goal that picks back up has not ended anywhere', () {
      final resumed = _goal(
        status: GoalStatus.stalled,
        endedAfter: 4,
      ).copyWith(status: GoalStatus.active, clearEndedAfter: true);
      expect(resumed.endedAfter, isNull);
    });

    test('a running goal writes no anchor at all', () {
      expect(_goal().toJson().containsKey('endedAfter'), isFalse);
    });
  });
}
