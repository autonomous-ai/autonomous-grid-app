import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/terminal/terminal_ime.dart';

void main() {
  group('terminalEdit — an input method rewrites what it already typed', () {
    test('Vietnamese Telex replaces the letter it just sent, so the edit is a '
        'rub-out and a new one — this is the bug: xterm could only append, and '
        'the user read "eẻ"', () {
      expect(terminalEdit('e', 'ẻ'), '$kTerminalDelete\u1EBB');
    });

    test('a whole syllable rewritten mid-word touches only the tail, so the '
        'word before the cursor is not retyped in front of the user', () {
      expect(terminalEdit('Tie', 'Tiế'), '$kTerminalDelete\u1EBF');
      expect(terminalEdit('xin cha', 'xin chà'), '$kTerminalDelete\u00E0');
    });

    test('ordinary typing is still just the character — nothing is rubbed out '
        'when nothing was replaced', () {
      expect(terminalEdit('', 'a'), 'a');
      expect(terminalEdit('ls -l', 'ls -la'), 'a');
    });

    test('backspace on a word already sent rubs out exactly one', () {
      expect(terminalEdit('abc', 'ab'), kTerminalDelete);
    });

    test('a rub-out is counted in graphemes, not code units — one press of '
        'Backspace erases one letter, and a combining mark would otherwise eat '
        'the letter in front of it', () {
      // e + U+0309 (combining hook above) is one letter to the person reading
      // it, and two code units.
      expect(terminalEdit('ẻ', ''), kTerminalDelete);
      // `n` + U+0309 is one letter to the person reading it, so erasing it
      // costs one press — two would have taken the `i` in front of it too.
      expect(terminalEdit('xin̉', 'xi'), kTerminalDelete);
    });

    test('an emoji is one rub-out too, and its halves are never split across '
        'the diff', () {
      expect(terminalEdit('hi 👍', 'hi '), kTerminalDelete);
      expect(terminalEdit('👍', '👎'), '$kTerminalDelete👎');
    });

    test('nothing changed means nothing is sent — the field notifies on caret '
        'moves as well as on text', () {
      expect(terminalEdit('same', 'same'), '');
      expect(terminalEdit('', ''), '');
    });

    test('the newline Enter leaves in the field is never sent, because the key '
        'handler has already sent the carriage return', () {
      expect(terminalEdit('ls', 'ls\n'), '');
      expect(terminalEdit('', '\r\n'), '');
    });
  });

  group(
    'endsRun — how much the input method is allowed to reach back over',
    () {
      test(
        'a space ends the run, so the hidden field cannot grow all session and '
        'a stale edit cannot reach across a word',
        () {
          expect(endsRun('xin '), isTrue);
          expect(endsRun('ls\n'), isTrue);
        },
      );

      test('mid-word it keeps going, which is exactly what Telex needs to turn '
          '"cha" into "chà"', () {
        expect(endsRun('cha'), isFalse);
        expect(endsRun(''), isFalse);
      });
    },
  );
}
