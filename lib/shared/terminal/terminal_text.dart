import 'package:xterm/xterm.dart';

/// The text under [range], with the gaps on screen left where they are.
///
/// Deliberately not `Buffer.getText`. That skips every cell nothing was ever
/// written to (`codePoint == 0`) instead of reading it as the space it looks
/// like, which is invisible for a shell — a shell writes its spaces — and
/// ruinous for a TUI, which draws a run of text, jumps the cursor, and draws
/// the next. Copying Claude Code's own permission warning out of the terminal
/// came back as "WARNING:Claude Code runningin Bypass Permissionsmode": the
/// sentence on screen with every gap deleted. It reached the clipboard that way
/// and would have reached the assistant that way through "Add to Chat".
String selectionText(Buffer buffer, BufferRange range) {
  final normalized = range.normalized;
  final out = StringBuffer();
  for (final segment in normalized.toSegments()) {
    if (segment.line < 0 || segment.line >= buffer.height) continue;
    final line = buffer.lines[segment.line];
    // xterm's own rule for where a newline goes: the line the selection began
    // on starts the text rather than following a break, and a line that is the
    // tail of a wrapped one is the same line as far as the reader is concerned.
    if (!(segment.line == normalized.begin.y ||
        segment.line == 0 ||
        line.isWrapped)) {
      out.write('\n');
    }
    out.write(lineText(line, segment.start ?? 0, segment.end ?? line.length));
  }
  return out.toString();
}

/// One line's cells, from [from] up to [to], as the characters they show.
///
/// Trailing blanks go: every terminal trims them on copy, and a line padded out
/// to the window's width would paste as a paragraph of trailing spaces.
String lineText(BufferLine line, int from, int to) {
  final out = StringBuffer();
  var index = from.clamp(0, line.length);
  final end = to.clamp(0, line.length);
  while (index < end) {
    final codePoint = line.getCodePoint(index);
    if (codePoint == 0) {
      out.write(' ');
      index++;
      continue;
    }
    out.writeCharCode(codePoint);
    // A double-width character owns the cell after it, and that cell is empty
    // by design — stepping over it is what keeps 漢 from copying as "漢 ".
    final width = line.getWidth(index);
    index += width > 1 ? width : 1;
  }
  return out.toString().trimRight();
}
