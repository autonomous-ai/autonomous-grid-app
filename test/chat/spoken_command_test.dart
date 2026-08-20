import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_command.dart';
import 'package:grid_app/features/chat/logic/commands/spoken_command.dart';

void main() {
  group('a repeat asked for in words', () {
    test('is run as it was said, because a spoken instruction never arrives '
        'with a slash on the front', () {
      final spoken = readSpokenCommand('lặp lại mỗi 30 phút kiểm tra deploy');

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, '30m kiểm tra deploy');
      expect(spoken?.certain, isTrue);
    });

    test('reads English the same way, so the two languages behave alike', () {
      final spoken = readSpokenCommand('run a loop every 2 hours check CI');

      expect(spoken?.call.argument, '2h check CI');
      expect(spoken?.certain, isTrue);
    });

    test('with no gap named still runs — a loop with no number is the '
        'self-paced one, not a reading with something missing', () {
      final spoken = readSpokenCommand('lặp lại việc kiểm tra deploy');

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, 'việc kiểm tra deploy');
      expect(spoken?.certain, isTrue);
    });

    test('a rhythm with no work in it is the one thing that cannot run, so it '
        'waits in the composer for the user to finish', () {
      final spoken = readSpokenCommand('lặp lại mỗi 30 phút');

      expect(spoken?.call.argument, '30m');
      expect(spoken?.certain, isFalse);
    });

    test('names the loop and the task, and runs on the words as typed', () {
      final spoken = readSpokenCommand(
        'làm loop cho task sau: research nguồn truyện mới',
      );

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, 'cho task sau: research nguồn truyện mới');
      expect(spoken?.certain, isTrue);
    });

    test('the same in English, so neither language waits on a keystroke the '
        'other one skips', () {
      expect(
        readSpokenCommand('start a loop watching the deploy')?.certain,
        isTrue,
      );
    });

    test('names the loop as a thing to make, which is how it is asked for '
        'once the task is already on screen', () {
      final spoken = readSpokenCommand('làm loop mỗi giờ quét X');

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, '1h quét X');
      expect(spoken?.certain, isTrue);
    });

    test('reads "mỗi giờ" — the commonest gap in the language this app is '
        'spoken in, and one a word boundary could never match', () {
      final spoken = readSpokenCommand('lặp lại mỗi giờ kiểm tra deploy');

      expect(spoken?.call.argument, '1h kiểm tra deploy');
      expect(spoken?.certain, isTrue);
    });

    test('reads the same ask in English', () {
      final spoken = readSpokenCommand(
        'make a loop every 30 minutes check the deploy',
      );

      expect(spoken?.call.argument, '30m check the deploy');
      expect(spoken?.certain, isTrue);
    });

    test('runs the same with a name in front of it — those words say who does '
        'it, not what is being asked', () {
      final spoken = readSpokenCommand('tao cần mày làm loop mỗi giờ quét X');

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, '1h quét X');
      expect(spoken?.certain, isTrue);
    });

    test(
      'ending one is understood too, so stopping is as easy as starting',
      () {
        expect(readSpokenCommand('dừng loop đi')?.call, (
          command: ChatCommand.loop,
          argument: 'stop',
        ));
        expect(readSpokenCommand('stop the loop')?.call, (
          command: ChatCommand.loop,
          argument: 'stop',
        ));
      },
    );
  });

  group('a goal asked for in words', () {
    test('becomes the goal, worded as the user worded it', () {
      final spoken = readSpokenCommand(
        'đặt mục tiêu tests trong test/auth pass',
      );

      expect(spoken?.call.command, ChatCommand.goal);
      expect(spoken?.call.argument, 'tests trong test/auth pass');
      expect(spoken?.certain, isTrue);
    });

    test('"set a goal to …" is the same ask', () {
      expect(
        readSpokenCommand('set a goal to get the build green')?.call.argument,
        'get the build green',
      );
    });

    test('clearing one is understood', () {
      expect(readSpokenCommand('xoá mục tiêu')?.call, (
        command: ChatCommand.goal,
        argument: 'clear',
      ));
    });
  });

  group('a task asked for in words', () {
    test('carries the whole "when" to the schedule reader, not just what '
        'follows it', () {
      final spoken = readSpokenCommand('mỗi sáng 8h tóm tắt hộp thư');

      expect(spoken?.call.command, ChatCommand.schedule);
      expect(spoken?.call.argument, 'mỗi sáng 8h tóm tắt hộp thư');
      expect(spoken?.certain, isTrue);
    });

    test('with no hour named is offered rather than saved — a task firing at '
        'an hour nobody chose is worse than one more keystroke', () {
      final spoken = readSpokenCommand('nhắc tôi gọi khách hàng');

      expect(spoken?.call.command, ChatCommand.schedule);
      expect(spoken?.certain, isFalse);
    });
  });

  group('sentences that must stay messages', () {
    test('a refusal never starts what it is refusing — this is the one that '
        'would be unforgivable, running unattended', () {
      for (final line in [
        'thôi đừng lặp lại nữa',
        "don't loop this",
        'không cần đặt mục tiêu đâu',
        'no need to schedule anything',
      ]) {
        expect(readSpokenCommand(line), isNull, reason: line);
      }
    });

    test('talking *about* a command is not asking for one', () {
      for (final line in [
        'cái loop hôm qua chạy sao rồi',
        'mục tiêu của dự án này là gì',
        'what does the goal command do',
      ]) {
        expect(
          readSpokenCommand(line)?.certain ?? false,
          isFalse,
          reason: line,
        );
      }
    });

    test('a line already typed as a command is left to the real parser', () {
      expect(readSpokenCommand('/loop 5m check the deploy'), isNull);
    });

    test('a refusal behind a name is still not a command — the guards that '
        'keep unattended work from starting on a misread run first', () {
      for (final line in [
        'tao cần mày đừng lặp lại nữa',
        'mình nhờ bạn khỏi đặt mục tiêu gì cả',
      ]) {
        expect(readSpokenCommand(line), isNull, reason: line);
      }
    });
  });

  group('the line the composer is filled with', () {
    test(
      'is exactly what would run, so the user reads it before it happens',
      () {
        expect(
          spokenCommandLine((command: ChatCommand.loop, argument: '30m check')),
          '/loop 30m check',
        );
        expect(
          spokenCommandLine((command: ChatCommand.goal, argument: '')),
          '/goal',
        );
      },
    );
  });

  group('the readings a review caught before they shipped', () {
    test('a gap buried mid-sentence is left where it is: the sentence runs '
        'whole and paces itself, rather than losing words nobody could put '
        'back', () {
      final spoken = readSpokenCommand(
        'keep checking the build every 10 minutes and tell me',
      );

      expect(spoken?.call.command, ChatCommand.loop);
      expect(spoken?.call.argument, 'the build every 10 minutes and tell me');
      expect(spoken?.certain, isTrue);
    });

    test('a duration inside the task is not the gap it repeats on — reading '
        'it as one would invent a rhythm and cut the task in half', () {
      final spoken = readSpokenCommand(
        'loop this check the last 24 hours of logs',
      );

      expect(spoken?.call.argument, 'check the last 24 hours of logs');
      expect(spoken?.call.argument, isNot(startsWith('24h')));
    });

    test('a plan that mentions a goal is a message, not a goal — this is the '
        'one that would cost the user the sentence they wrote', () {
      expect(
        readSpokenCommand("I'll keep working until the tests pass, then push"),
        isNull,
      );
      expect(readSpokenCommand('do not keep checking the deploy'), isNull);
      expect(readSpokenCommand('đừng để lặp lại mỗi 30 phút nữa'), isNull);
    });
  });
}
