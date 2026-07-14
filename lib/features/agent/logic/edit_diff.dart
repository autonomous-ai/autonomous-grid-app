/// What a line in a proposed file change is: unchanged, going away, or new.
enum DiffLineKind { context, removed, added }

/// One line of the change the agent wants to make to a file.
class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffLineKind kind;
  final String text;
}

/// The change from [oldText] to [newText], as the lines to show the user.
///
/// The agent proposes a file's whole new contents, so showing all of it would
/// bury a two-line fix in a thousand unchanged ones. This keeps the lines that
/// actually differ, plus [context] lines around them for orientation, and stops
/// at [maxLines] — approving a change you can't read isn't consent.
///
/// A deliberately simple diff: the common opening and closing lines are trimmed
/// and everything between them counts as changed. It never *understates* a
/// change (nothing edited is hidden), it just doesn't pair lines up as neatly as
/// a real LCS diff would.
List<DiffLine> buildEditDiff(
  String? oldText,
  String newText, {
  int context = 2,
  int maxLines = 200,
}) {
  final before = oldText == null ? const <String>[] : _lines(oldText);
  final after = _lines(newText);

  var head = 0;
  while (head < before.length &&
      head < after.length &&
      before[head] == after[head]) {
    head++;
  }
  var tail = 0;
  while (tail < before.length - head &&
      tail < after.length - head &&
      before[before.length - 1 - tail] == after[after.length - 1 - tail]) {
    tail++;
  }

  final lines = <DiffLine>[
    for (var i = (head - context).clamp(0, head); i < head; i++)
      DiffLine(DiffLineKind.context, before[i]),
    for (var i = head; i < before.length - tail; i++)
      DiffLine(DiffLineKind.removed, before[i]),
    for (var i = head; i < after.length - tail; i++)
      DiffLine(DiffLineKind.added, after[i]),
    for (
      var i = after.length - tail;
      i < (after.length - tail + context).clamp(0, after.length);
      i++
    )
      DiffLine(DiffLineKind.context, after[i]),
  ];

  if (lines.length <= maxLines) return lines;
  final shown = lines.take(maxLines).toList();
  final hidden = lines.length - maxLines;
  return [
    ...shown,
    DiffLine(DiffLineKind.context, '… and $hidden more lines'),
  ];
}

/// Splits into lines without inventing a trailing empty one for the final
/// newline — that phantom line would read as a change that isn't there.
List<String> _lines(String text) {
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
