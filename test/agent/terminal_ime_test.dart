import 'package:flutter/services.dart';
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

  group('terminalKeyLane — which keyboard a key belongs to', () {
    TerminalKeyLane lane(
      LogicalKeyboardKey key, {
      String? character,
      bool modified = false,
      bool hasRun = false,
      bool composing = false,
    }) => terminalKeyLane(
      key: key,
      character: character,
      modified: modified,
      hasRun: hasRun,
      composing: composing,
    );

    test('a plain letter is declined so macOS offers it to the input method — '
        'this is the bug: xterm inserted it and answered "handled", and a key '
        'the framework claims never reaches Telex at all', () {
      expect(
        lane(LogicalKeyboardKey.keyE, character: 'e'),
        TerminalKeyLane.input,
      );
      expect(
        lane(LogicalKeyboardKey.space, character: ' '),
        TerminalKeyLane.input,
      );
    });

    test('Enter, Tab and Escape stay with the terminal, which knows how to '
        'spell them for the buffer the program is on', () {
      expect(
        lane(LogicalKeyboardKey.enter, character: '\r'),
        TerminalKeyLane.terminal,
      );
      expect(
        lane(LogicalKeyboardKey.tab, character: '\t'),
        TerminalKeyLane.terminal,
      );
      expect(
        lane(LogicalKeyboardKey.escape, character: '\x1b'),
        TerminalKeyLane.terminal,
      );
    });

    test('a key with no character of its own — an arrow, a function key — is '
        "the terminal's", () {
      expect(lane(LogicalKeyboardKey.arrowUp), TerminalKeyLane.terminal);
      expect(
        lane(LogicalKeyboardKey.f1, character: ''),
        TerminalKeyLane.terminal,
      );
    });

    test('a chord is never text, so ctrl-C still interrupts and ⌘V still '
        'pastes', () {
      expect(
        lane(LogicalKeyboardKey.keyC, character: 'c', modified: true),
        TerminalKeyLane.terminal,
      );
    });

    test('Backspace goes wherever the text is: to the field while a word is '
        'still being composed, so the two agree on what is on the line, and to '
        'the program when the field is empty and there is nothing to edit', () {
      expect(
        lane(LogicalKeyboardKey.backspace, hasRun: true),
        TerminalKeyLane.input,
      );
      expect(lane(LogicalKeyboardKey.backspace), TerminalKeyLane.terminal);
    });
  });

  group('terminalKeyLane — a candidate window owns the whole keyboard', () {
    test('Enter commits the chosen word rather than running the line, and the '
        'arrows walk the candidates rather than the shell history — sending '
        'either to the program as well would run a command the user was only '
        'picking a word with', () {
      expect(
        terminalKeyLane(
          key: LogicalKeyboardKey.enter,
          character: '\r',
          modified: false,
          hasRun: true,
          composing: true,
        ),
        TerminalKeyLane.input,
      );
      expect(
        terminalKeyLane(
          key: LogicalKeyboardKey.arrowDown,
          character: null,
          modified: false,
          hasRun: true,
          composing: true,
        ),
        TerminalKeyLane.input,
      );
    });

    test('a chord still reaches the terminal, so ctrl-C interrupts even with a '
        'candidate window up', () {
      expect(
        terminalKeyLane(
          key: LogicalKeyboardKey.keyC,
          character: 'c',
          modified: true,
          hasRun: true,
          composing: true,
        ),
        TerminalKeyLane.terminal,
      );
    });
  });

  group('isModifierKey — a held modifier must not end the run', () {
    test('a Shift held for a capital in the middle of a Vietnamese word sends '
        'nothing, so it cannot count as moving on from that word', () {
      expect(isModifierKey(LogicalKeyboardKey.shiftLeft), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.metaRight), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.capsLock), isTrue);
    });

    test('a key that does send something is not one', () {
      expect(isModifierKey(LogicalKeyboardKey.enter), isFalse);
      expect(isModifierKey(LogicalKeyboardKey.keyA), isFalse);
    });
  });
}
