import 'dart:math';

import 'package:xterm/xterm.dart';

/// How many lines of a terminal one message may carry.
///
/// The **tail**, never the head: what makes somebody attach a terminal is the
/// thing that just happened in it. Two hundred is a screenful of a tall window
/// plus the command that filled it.
const int kTerminalCaptureLines = 200;

/// The same limit in characters, for the reason `kFileTextBudget` exists: two
/// hundred lines of a wide window is forty thousand characters, and one
/// attachment must never crowd out the conversation it was attached to.
const int kTerminalCaptureChars = 8000;

/// What a terminal is showing, cut to what a prompt can carry. [truncated] says
/// the capture starts part-way in, so the message can admit it.
typedef TerminalCapture = ({String text, bool truncated});

/// Reads the end of [terminal], or null when there is nothing there worth
/// sending.
///
/// Null rather than an empty block: a terminal opened and never typed into is a
/// prompt and some blank rows, and a message carrying that says the user
/// attached something when they attached nothing.
///
/// Reads a range rather than the whole buffer — scrollback is ten thousand
/// lines, and building all of it into a string to keep the last two hundred is
/// most of a megabyte thrown away.
TerminalCapture? captureTerminal(
  Terminal terminal, {
  int maxLines = kTerminalCaptureLines,
  int maxChars = kTerminalCaptureChars,
}) {
  final buffer = terminal.buffer;
  final height = buffer.height;
  if (height <= 0) return null;

  // A screenful more than we mean to keep. The rows below the cursor are part of
  // the buffer and are blank, so asking for exactly the last two hundred rows of
  // a long scrollback hands back a hundred and eighty lines and twenty blanks.
  final from = max(0, height - maxLines - buffer.viewHeight);
  final raw = buffer.getText(
    BufferRangeLine(
      CellOffset(0, from),
      CellOffset(max(0, buffer.viewWidth - 1), height - 1),
    ),
  );

  var lines = _withoutBlankEdges(raw);
  if (lines.isEmpty) return null;

  var truncated = from > 0;
  if (lines.length > maxLines) {
    lines = lines.sublist(lines.length - maxLines);
    truncated = true;
  }

  var text = lines.join('\n');
  if (text.length > maxChars) {
    // Cut from the front, for the same reason the tail is what we took: the end
    // of the capture is the end of the output, which is where the failure is.
    text = text.substring(text.length - maxChars).trimLeft();
    truncated = true;
  }
  return (text: text, truncated: truncated);
}

/// Drops the padding a terminal screen is made of: every row comes back the full
/// width of the window, and the rows below the cursor are empty.
List<String> _withoutBlankEdges(String raw) {
  final lines = [for (final line in raw.split('\n')) line.trimRight()];
  var start = 0;
  while (start < lines.length && lines[start].isEmpty) {
    start++;
  }
  var end = lines.length;
  while (end > start && lines[end - 1].isEmpty) {
    end--;
  }
  return lines.sublist(start, end);
}
