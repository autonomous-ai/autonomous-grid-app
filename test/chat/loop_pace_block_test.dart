import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_loop.dart';
import 'package:grid_app/features/chat/logic/commands/loop_pace_block.dart';

String _reply(String block) =>
    'The build is still running, about 15 minutes left.\n\n'
    '```grid-loop\n$block\n```';

void main() {
  group('reading what an iteration asked for next', () {
    test('the gap it named becomes the wait, so the one that saw the work sets '
        'the pace', () {
      final asked = parseLoopPaceBlock(
        _reply('{"next": "20m", "why": "the build has 15 minutes left"}'),
      );
      expect(asked?.next, const Duration(minutes: 20));
      expect(asked?.why, 'the build has 15 minutes left');
      expect(asked?.stop, isFalse);
      expect(asked?.quiet, isFalse);
    });

    test('a gap is read in the same grammar /loop itself takes, so 1h means '
        'the same thing in both places', () {
      expect(
        parseLoopPaceBlock(_reply('{"next": "1h"}'))?.next,
        const Duration(hours: 1),
      );
      expect(
        parseLoopPaceBlock(_reply('{"next": "45s"}'))?.next,
        kMinPacedDelay,
      );
    });

    test('a gap beyond what a loop may wait is capped rather than refused — an '
        'assistant asking for a day still gets the longest wait there is', () {
      expect(
        parseLoopPaceBlock(_reply('{"next": "1d"}'))?.next,
        kMaxPacedDelay,
      );
      expect(
        parseLoopPaceBlock(_reply('{"next": "2h"}'))?.next,
        kMaxPacedDelay,
      );
    });

    test('stop ends the loop, which is how a finished job is meant to end', () {
      final asked = parseLoopPaceBlock(
        _reply('{"stop": true, "why": "the deploy finished"}'),
      );
      expect(asked?.stop, isTrue);
      expect(asked?.why, 'the deploy finished');
    });

    test('quiet marks an iteration with no news, so a night of them can '
        'collapse to a count', () {
      final asked = parseLoopPaceBlock(_reply('{"quiet": true, "next": "1h"}'));
      expect(asked?.quiet, isTrue);
      expect(asked?.next, const Duration(hours: 1));
    });

    test('a reply with no block asks for nothing — the loop keeps its own pace '
        'rather than being stopped by silence', () {
      expect(parseLoopPaceBlock('The build is still running.'), isNull);
    });

    test('the last block wins, so a reply that shows the format before using '
        'it acts on the decision and not the example', () {
      final reply =
          'Here is how I would report it:\n\n'
          '```grid-loop\n{"next": "5m"}\n```\n\n'
          'But the build only just started, so:\n\n'
          '```grid-loop\n{"next": "45m", "why": "just started"}\n```';
      expect(parseLoopPaceBlock(reply)?.next, const Duration(minutes: 45));
    });

    test('a malformed block reads as no block — one bad reply must never stop '
        'a loop the user is relying on', () {
      expect(parseLoopPaceBlock(_reply('{"next": "20m",}')), isNull);
      expect(parseLoopPaceBlock(_reply('twenty minutes')), isNull);
      expect(parseLoopPaceBlock(_reply('["20m"]')), isNull);
    });

    test('an unreadable gap leaves the caller to fall back, rather than '
        'inventing a number the assistant never gave', () {
      final asked = parseLoopPaceBlock(_reply('{"next": "soonish"}'));
      expect(asked, isNotNull);
      expect(asked?.next, isNull);
    });

    test('an empty block is a well-formed "carry on as you were"', () {
      final asked = parseLoopPaceBlock(_reply('{}'));
      expect(asked, isNotNull);
      expect(asked?.next, isNull);
      expect(asked?.stop, isFalse);
    });
  });

  group('taking the block back out of the answer', () {
    test('the reader is left with the answer and none of the machinery', () {
      final clean = stripLoopPaceBlock(_reply('{"next": "20m"}'));
      expect(clean, 'The build is still running, about 15 minutes left.');
    });

    test('a reply that never carried one is returned untouched', () {
      const plain = 'The build is still running.';
      expect(stripLoopPaceBlock(plain), same(plain));
    });

    test(
      'every block goes, so a reply that wrote two leaves neither behind',
      () {
        final clean = stripLoopPaceBlock(
          'One\n\n```grid-loop\n{"next": "5m"}\n```\n\nTwo\n\n'
          '```grid-loop\n{"stop": true}\n```',
        );
        expect(clean.contains('grid-loop'), isFalse);
        expect(clean, contains('One'));
        expect(clean, contains('Two'));
      },
    );

    test("a fence of another kind is the user's content and stays", () {
      const chart = 'Look:\n\n```chart\n{"labels": ["a"]}\n```';
      expect(stripLoopPaceBlock(chart), chart);
    });
  });

  group('drawing a beat the app added a line to', () {
    test('the line the app appended is not drawn as the user\'s words — an '
        'overnight loop would otherwise show them asking for a grid-loop '
        'block on every iteration', () {
      final sent =
          'research nguồn truyện mới\n\n'
          '${loopBeatFooter(selfPaced: true)}';

      expect(withoutLoopBeatFooter(sent), 'research nguồn truyện mới');
    });

    test('the fixed-interval footer comes off too, since both are the app '
        'talking and neither was typed', () {
      final sent = 'kiểm tra deploy\n\n${loopBeatFooter(selfPaced: false)}';

      expect(withoutLoopBeatFooter(sent), 'kiểm tra deploy');
    });

    test('an ordinary message is returned untouched, including one that '
        'happens to say the word', () {
      expect(withoutLoopBeatFooter('sửa cái loop đi'), 'sửa cái loop đi');
      expect(
        withoutLoopBeatFooter('cách grid-loop hoạt động thế nào'),
        'cách grid-loop hoạt động thế nào',
      );
    });
  });

  group('what the app asks for with each beat', () {
    test('a self-paced loop is asked for the gap; one on the user\'s own '
        'interval is only ever asked whether to stop', () {
      expect(loopBeatFooter(selfPaced: true), contains('"next"'));
      expect(loopBeatFooter(selfPaced: false), isNot(contains('"next"')));
      for (final selfPaced in [true, false]) {
        expect(loopBeatFooter(selfPaced: selfPaced), contains('"stop"'));
        expect(loopBeatFooter(selfPaced: selfPaced), contains(kLoopBlockFence));
      }
    });
  });
}
