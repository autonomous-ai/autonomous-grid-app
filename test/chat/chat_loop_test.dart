import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_loop.dart';

final _start = DateTime.utc(2026, 8, 17, 9);

ChatLoop _loop({
  Duration? interval = const Duration(minutes: 5),
  LoopStatus status = LoopStatus.running,
  int iterations = 0,
  DateTime? nextAt,
  String? pacing,
  int quietStreak = 0,
  bool continuous = false,
}) => ChatLoop(
  prompt: 'check the deploy',
  interval: interval,
  startedAt: _start,
  nextAt: nextAt ?? _start.add(const Duration(minutes: 5)),
  status: status,
  iterations: iterations,
  pacing: pacing,
  quietStreak: quietStreak,
  continuous: continuous,
);

void main() {
  group('reading what the user asked to repeat', () {
    test('a leading interval sets the gap and the rest is the prompt', () {
      final asked = parseLoopArgument('5m check whether the deploy finished');
      expect(asked.interval, const Duration(minutes: 5));
      expect(asked.prompt, 'check whether the deploy finished');
    });

    test('no interval means the assistant picks its own pace', () {
      final asked = parseLoopArgument('check the deploy');
      expect(asked.interval, isNull);
      expect(asked.prompt, 'check the deploy');
    });

    test('seconds round up to the one-minute floor, so /loop 30s is a promise '
        'the app can keep', () {
      expect(parseLoopArgument('30s watch it').interval, kMinLoopInterval);
    });

    test('hours and days are read as themselves', () {
      expect(parseLoopInterval('2h'), const Duration(hours: 2));
      expect(parseLoopInterval('1d'), const Duration(days: 1));
    });

    test('a word that only looks like a gap is part of the prompt — "5 minutes '
        'of logs" is not a cadence', () {
      final asked = parseLoopArgument('5 minutes of logs, summarise them');
      expect(asked.interval, isNull);
      expect(asked.prompt, '5 minutes of logs, summarise them');
    });

    test('an interval with nothing to run leaves no prompt, so the caller can '
        'say what is missing instead of inventing an errand', () {
      expect(parseLoopArgument('5m').prompt, isEmpty);
      expect(parseLoopArgument('').prompt, isEmpty);
    });

    test('a leading "continuous" means back-to-back, and the rest is the task '
        '— for "keep building this project, never stop"', () {
      final asked = parseLoopArgument('continuous keep improving the project');
      expect(asked.continuous, isTrue);
      expect(asked.interval, isNull);
      expect(asked.prompt, 'keep improving the project');
    });

    test('a fixed or self-paced loop is not continuous', () {
      expect(parseLoopArgument('5m watch it').continuous, isFalse);
      expect(parseLoopArgument('watch it').continuous, isFalse);
    });
  });

  group('continuous — keep working, never stop', () {
    test('a continuous loop is neither self-paced nor fixed', () {
      final loop = _loop(interval: null, continuous: true);
      expect(loop.isContinuous, isTrue);
      expect(loop.isSelfPaced, isFalse);
    });

    test('it survives a round-trip through JSON', () {
      final read = ChatLoop.fromJson(
        _loop(interval: null, continuous: true, iterations: 4).toJson(),
      );
      expect(read?.isContinuous, isTrue);
      expect(read?.iterations, 4);
    });

    test(
      'the bar says it works continuously until stopped, with no countdown',
      () {
        final label = loopBarLabel(
          _loop(interval: null, continuous: true, iterations: 7),
          _start,
        );
        expect(label, contains('Working continuously'));
        expect(label, contains('7 so far'));
        expect(label, contains('until you stop it'));
        expect(label, isNot(contains('next in')));
      },
    );
  });

  group('the pace a self-paced loop picks', () {
    test('a number of minutes with a reason after it', () {
      final paced = parseLoopDelay('15\nThe PR is quiet now.');
      expect(paced.delay, const Duration(minutes: 15));
      expect(paced.reason, 'The PR is quiet now.');
    });

    test('it is clamped to what a loop may wait, whatever the model says', () {
      expect(parseLoopDelay('0\nnow').delay, kMinPacedDelay);
      expect(parseLoopDelay('999\nlater').delay, kMaxPacedDelay);
    });

    test('an unreadable answer waits ten minutes rather than hammering or '
        'stopping', () {
      expect(parseLoopDelay('whenever').delay, const Duration(minutes: 10));
      expect(parseLoopDelay('whenever').reason, isNotEmpty);
    });
  });

  group('surviving a restart', () {
    test('a loop running when the app closed comes back running, with its '
        'count intact — the app arms its timer again, and a loop that forgot '
        'how far it had got would re-do the work from zero', () {
      final read = ChatLoop.fromJson(_loop(iterations: 3).toJson());
      expect(read?.status, LoopStatus.running);
      expect(read?.prompt, 'check the deploy');
      expect(read?.iterations, 3);
      expect(read?.interval, const Duration(minutes: 5));
    });

    test('a loop the user stopped stays stopped, restart or not', () {
      final read = ChatLoop.fromJson(
        _loop(status: LoopStatus.stopped).toJson(),
      );
      expect(read?.status, LoopStatus.stopped);
    });

    test('a run of quiet iterations survives the restart, so the count on the '
        'bar does not start over as if the night had been eventful', () {
      final read = ChatLoop.fromJson(_loop(quietStreak: 4).toJson());
      expect(read?.quietStreak, 4);
    });

    test('a loop the assistant finished stays finished — a restart must not '
        'start a job that is already done back up', () {
      final read = ChatLoop.fromJson(
        _loop(status: LoopStatus.finished).toJson(),
      );
      expect(read?.status, LoopStatus.finished);
      expect(read?.isRunning, isFalse);
    });

    test('a self-paced loop keeps having no interval', () {
      final read = ChatLoop.fromJson(_loop(interval: null).toJson());
      expect(read?.isSelfPaced, isTrue);
    });

    test('half-written JSON reads as no loop at all', () {
      expect(ChatLoop.fromJson(null), isNull);
      expect(ChatLoop.fromJson({'prompt': 'x'}), isNull);
    });
  });

  group('the seven-day ceiling', () {
    test('a loop is done once seven days have passed', () {
      expect(_loop().hasExpired(_start.add(const Duration(days: 6))), isFalse);
      expect(_loop().hasExpired(_start.add(const Duration(days: 7))), isTrue);
    });
  });

  group('what the bar says', () {
    test('a fixed loop names its cadence and counts down to the next run', () {
      final label = loopBarLabel(
        _loop(iterations: 2, nextAt: _start.add(const Duration(minutes: 8))),
        _start.add(const Duration(minutes: 5)),
      );
      expect(label, contains('every 5m'));
      expect(label, contains('2 so far'));
      expect(label, contains('next in 3m'));
    });

    test('a self-paced loop says so, and why it chose the gap it did', () {
      final label = loopBarLabel(
        _loop(interval: null, pacing: 'the build is nearly done'),
        _start,
      );
      expect(label, contains('at a pace it picks'));
      expect(label, contains('the build is nearly done'));
    });

    test('stopped and expired read differently — "you stopped it" and "it ran '
        'out of its week" are not the same news', () {
      final stopped = loopBarLabel(_loop(status: LoopStatus.stopped), _start);
      final expired = loopBarLabel(_loop(status: LoopStatus.expired), _start);
      expect(stopped, contains('Stopped repeating'));
      expect(expired, contains('7 days'));
      expect(stopped, isNot(expired));
    });

    test('a loop the assistant ended says it finished, and why — telling a '
        'user they stopped something that finished on its own is a lie', () {
      final finished = loopBarLabel(
        _loop(status: LoopStatus.finished, pacing: 'the deploy went out'),
        _start,
      );
      expect(finished, startsWith('Finished:'));
      expect(finished, contains('the deploy went out'));
      expect(finished, isNot(contains('Stopped repeating')));
    });

    test('a quiet run only shows once it means something — two of them is a '
        'coincidence, three is the news that nothing is happening', () {
      expect(
        loopBarLabel(_loop(quietStreak: 2), _start),
        isNot(contains('no change')),
      );
      expect(
        loopBarLabel(_loop(quietStreak: 3), _start),
        contains('3 with no change'),
      );
    });
  });
  group('the line under the composer while it runs', () {
    test('it names the prompt and counts down, and leaves the cadence and the '
        "pacer's reason to /loop", () {
      final note = loopStatusNote(
        _loop(iterations: 2, nextAt: _start.add(const Duration(minutes: 8))),
        _start.add(const Duration(minutes: 5)),
      );
      expect(note, contains('check the deploy'));
      expect(note, contains('2 so far'));
      expect(note, contains('next in 3m'));
      expect(note, isNot(contains('every 5m')));
    });

    test('a continuous loop counts turns and never a countdown — there is no '
        'next time to name', () {
      final note = loopStatusNote(
        _loop(interval: null, continuous: true, iterations: 7),
        _start,
      );
      expect(note, contains('7 so far'));
      expect(note, isNot(contains('next in')));
    });
  });

  group('where it ended', () {
    test('the anchor survives a restart, so the stopped line stays at the turn '
        'it stopped on', () {
      final ended = ChatLoop(
        prompt: 'check the deploy',
        interval: const Duration(minutes: 5),
        startedAt: _start,
        nextAt: _start,
        status: LoopStatus.stopped,
        endedAfter: 6,
      );
      expect(ChatLoop.fromJson(ended.toJson())?.endedAfter, 6);
    });

    test('a running loop writes no anchor at all', () {
      expect(_loop().toJson().containsKey('endedAfter'), isFalse);
    });
  });
}
