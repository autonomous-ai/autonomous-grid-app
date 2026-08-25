import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/terminal/scroll_region_terminal.dart';

/// The escape sequences an agent's CLI actually writes, and what the emulator
/// behind the chat has to make of them.
///
/// Read off a real Codex session (v0.144.6) with a pty recorder: the CLI keeps
/// a block pinned at the bottom of the screen and pushes finished lines past it
/// into the scrollback, which is the whole of a chat transcript. Stock `xterm`
/// drops every one of those lines and then throws out of `Terminal.write` — the
/// pty's own output listener — so the screen stops at whatever landed last.
void main() {
  /// Everything the buffer holds, scrollback first, as trimmed text.
  List<String> allLines(ScrollRegionTerminal term) => [
    for (var i = 0; i < term.buffer.lines.length; i++)
      term.buffer.lines[i].getText().trimRight(),
  ];

  ScrollRegionTerminal open({int rows = 10, int columns = 40}) {
    final term = ScrollRegionTerminal(maxLines: 1000);
    term.resize(columns, rows);
    return term;
  }

  group('an agent CLI pushing lines past its pinned block', () {
    test('keeps the finished lines, in order, above the fold', () {
      final term = open();
      // Codex's idiom, verbatim: pin the bottom block, reverse-index it down to
      // make room, then line-feed the transcript into the region above it.
      term.write('\x1b[8;10r\x1b[8;1H\x1bM\x1bM\x1b[r');
      term.write('\x1b[1;9r\x1b[7;1H');
      for (var i = 1; i <= 12; i++) {
        term.write('\r\nfinished line $i');
      }
      term.write('\x1b[r');

      final text = allLines(term);
      expect(
        term.buffer.scrollBack,
        greaterThan(0),
        reason:
            'a transcript with nothing above the fold cannot be scrolled '
            'back to, which is what the user sees as "it lost my message"',
      );
      final kept = text.where((line) => line.startsWith('finished line'));
      expect(kept, [for (var i = 1; i <= 12; i++) 'finished line $i']);
    });

    test('never throws, so the pty keeps being read after the first frame', () {
      final term = open();
      // The exact pair that broke it: a reverse index inside a region leaves a
      // line in two slots, and the next line feed at a region's bottom detaches
      // it out from under the buffer.
      expect(() {
        for (var frame = 0; frame < 20; frame++) {
          term.write('\x1b[6;10r\x1b[6;1H\x1bM\x1bM\x1b[r');
          term.write('\x1b[1;7r\x1b[5;1H\r\nframe $frame\r\nmore\x1b[r');
        }
      }, returnsNormally);
      expect(allLines(term), contains('frame 19'));
    });

    test('leaves the block below the region where the CLI pinned it', () {
      final term = open();
      term.write('\x1b[8;1H› pinned prompt');
      term.write('\x1b[1;7r\x1b[7;1H\r\nscrolled in\x1b[r');

      // Row 8 is outside the region, so it must not have moved with the lines
      // that scrolled past it — a prompt that slides up the screen every turn
      // is the CLI redrawing over its own output.
      final rows = allLines(term);
      expect(rows[rows.length - 10 + 7], '› pinned prompt');
    });
  });

  group('scrolling a region', () {
    test('moves what is inside it and blanks the rows left behind', () {
      final term = open(rows: 6);
      for (var i = 1; i <= 6; i++) {
        term.write('row $i');
        if (i < 6) term.write('\r\n');
      }
      // Region rows 2..5, scrolled up by one: rows 3..5 move to 2..4 and row 5
      // is blanked. Rows 1 and 6 are outside it and stay put.
      term.write('\x1b[2;5r\x1b[2S\x1b[r');

      expect(allLines(term), ['row 1', 'row 4', 'row 5', '', '', 'row 6']);
    });

    test('scrolling back down puts blanks at the top of the region', () {
      final term = open(rows: 6);
      for (var i = 1; i <= 6; i++) {
        term.write('row $i');
        if (i < 6) term.write('\r\n');
      }
      term.write('\x1b[2;5r\x1b[1T\x1b[r');

      expect(allLines(term), ['row 1', '', 'row 2', 'row 3', 'row 4', 'row 6']);
    });

    test('deleting lines closes the gap from the cursor down', () {
      final term = open(rows: 6);
      for (var i = 1; i <= 6; i++) {
        term.write('row $i');
        if (i < 6) term.write('\r\n');
      }
      // Two lines deleted at row 2, inside a region that ends at row 5: rows 4
      // and 5 move up, and the two rows at the bottom of the region go blank.
      term.write('\x1b[2;5r\x1b[2;1H\x1b[2M\x1b[r');

      expect(allLines(term), ['row 1', 'row 4', 'row 5', '', '', 'row 6']);
    });
  });

  test('a plain shell still fills the scrollback line by line', () {
    final term = open(rows: 4);
    for (var i = 1; i <= 10; i++) {
      term.write('line $i\r\n');
    }

    expect(term.buffer.scrollBack, 7);
    expect(allLines(term).first, 'line 1');
  });
}
