/// Editing the composer's text box from code — pasting, dropping a path in —
/// as pure arithmetic over a string and a cursor, so it can be tested without a
/// widget.
library;

/// What the field holds after [insert] lands at the selection.
///
/// [start]/[end] are the selected range; equal means a plain cursor and a
/// negative [start] means the field isn't focused, in which case the text goes
/// on the end — where a person who never clicked into the box expects it.
({String text, int cursor}) insertIntoField(
  String text, {
  required int start,
  required int end,
  required String insert,
}) {
  final from = start < 0 ? text.length : start.clamp(0, text.length);
  if (insert.isEmpty) return (text: text, cursor: from);
  final to = start < 0 ? text.length : end.clamp(from, text.length);
  return (
    text: text.replaceRange(from, to, insert),
    cursor: from + insert.length,
  );
}

/// File paths as they go into a message: space-separated, with a trailing space
/// so the sentence can carry on straight after them.
///
/// Blank entries are dropped, and an empty list gives an empty string — nothing
/// to insert, rather than a stray space.
String pathsForMessage(Iterable<String> paths) {
  final tokens = [
    for (final path in paths)
      if (path.trim().isNotEmpty) path.trim(),
  ];
  return tokens.isEmpty ? '' : '${tokens.join(' ')} ';
}
