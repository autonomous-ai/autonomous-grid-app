import 'package:flutter/foundation.dart';

import 'unified_diff.dart';

/// A run of lines someone highlighted in a file's diff, on its way to being a
/// question about them.
///
/// The lines are carried as text rather than as a pointer, because a pointer is
/// exactly what the assistant can't follow here: it has no way of knowing which
/// part of a file was under the cursor. [startLine] and [endLine] are the
/// pointer *as well*, when the highlight turns out to be one unbroken stretch of
/// the file as it stands — a number the assistant can go back to after its own
/// edits have moved the text.
@immutable
class DiffExcerpt {
  const DiffExcerpt({
    required this.path,
    required this.text,
    this.startLine,
    this.endLine,
  });

  /// The file, relative to the repository root — Git's own form.
  final String path;

  /// The highlighted lines, as they read in the diff.
  final String text;

  /// Where the run sits in the file *after* the change, 1-based and inclusive.
  ///
  /// Null unless every line of it is one unbroken stretch of that file: a drag
  /// across two hunks, a highlight of nothing but deleted lines, a drag down one
  /// column of the side-by-side view. The lines themselves are still exact; only
  /// a number pointing at the wrong place would have been the lie.
  final int? startLine;
  final int? endLine;
}

/// What [selected] — the text the selection handed back — covers in [rows], the
/// diff's lines in the order they are drawn.
///
/// Returns null only for a highlight with nothing in it. Everything else comes
/// back as an excerpt: the lines are located in [rows] where they can be, which
/// is what puts numbers on them and repairs the newlines, and the raw highlight
/// stands in where they can't (the side-by-side view draws its two columns
/// interleaved, so a drag down one of them matches no run of this list).
///
/// Pure, and the reason the feature can be trusted: a chip that named the wrong
/// lines would send the assistant to the wrong place with every appearance of
/// precision.
DiffExcerpt? diffExcerptFor({
  required String path,
  required List<DiffRow> rows,
  required String selected,
}) {
  if (selected.trim().isEmpty) return null;
  // Matched without the line breaks, so it makes no difference whether they
  // survived the trip out of the selection.
  final wanted = selected.replaceAll('\r', '').replaceAll('\n', '');
  final found = wanted.isEmpty ? null : _locate(rows, wanted);
  if (found == null) return DiffExcerpt(path: path, text: selected);

  final (:first, :start, :last, :end) = found;
  final lines = [
    for (var i = first; i <= last; i++)
      rows[i].text.substring(
        i == first ? start : 0,
        i == last ? end : rows[i].text.length,
      ),
  ];
  final numbers = _numbering(rows.sublist(first, last + 1));
  return DiffExcerpt(
    path: path,
    text: lines.join('\n'),
    startLine: numbers?.start,
    endLine: numbers?.end,
  );
}

/// The first run of [rows] whose text reads as [wanted], as the offsets that
/// bound it: from [start] in row [first] up to [end] in row [last].
({int first, int start, int last, int end})? _locate(
  List<DiffRow> rows,
  String wanted,
) {
  final head = wanted[0];
  for (var i = 0; i < rows.length; i++) {
    final text = rows[i].text;
    // Only the places this row could begin the run — every occurrence of the
    // highlight's first character. Without this the scan is every offset of
    // every line of the file.
    for (
      var start = text.indexOf(head);
      start >= 0;
      start = text.indexOf(head, start + 1)
    ) {
      final tail = _matchFrom(rows, i, start, wanted);
      if (tail != null) {
        return (first: i, start: start, last: tail.row, end: tail.upto);
      }
    }
  }
  return null;
}

/// Walks [rows] from [start] in row [from], checking they spell [wanted], and
/// says where the last of it lands. Null the moment they don't.
({int row, int upto})? _matchFrom(
  List<DiffRow> rows,
  int from,
  int start,
  String wanted,
) {
  var taken = 0;
  var offset = start;
  for (var row = from; row < rows.length; row++) {
    final text = rows[row].text;
    final left = wanted.length - taken;
    final available = text.length - offset;
    // The rest of the highlight has to be here, at the head of this row.
    if (available >= left) {
      if (!text.startsWith(wanted.substring(taken), offset)) return null;
      return (row: row, upto: offset + left);
    }
    if (available > 0 && !wanted.startsWith(text.substring(offset), taken)) {
      return null;
    }
    taken += available;
    // An empty line takes nothing and is simply passed through, which is what
    // makes a highlight that spans one still line up.
    offset = 0;
  }
  return null;
}

/// Where [rows] sit in the file as it stands, or null when they can't be said
/// to sit anywhere in it.
///
/// Only the new file's numbers, because `main.dart:11` means line 11 of the file
/// on disk to everyone who reads it — and a deleted line is not in that file at
/// all. A highlight made only of deletions therefore travels as text with no
/// numbers, which is the true answer.
///
/// Numbers must also run unbroken: a drag across a hunk boundary covers lines
/// the file has between them that were never on screen, and `3-48` would be a
/// claim about 46 lines nobody selected.
({int start, int end})? _numbering(List<DiffRow> rows) {
  final numbers = [
    for (final row in rows)
      if (row.newLine case final int line) line,
  ];
  if (numbers.isEmpty) return null;
  final unbroken = numbers.last - numbers.first + 1 == numbers.length;
  return unbroken ? (start: numbers.first, end: numbers.last) : null;
}
