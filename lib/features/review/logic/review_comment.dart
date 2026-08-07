import 'package:flutter/foundation.dart';

import 'unified_diff.dart';

/// Which file a commented line belongs to — the one before the change or the
/// one after.
///
/// It has to be said: a removed line exists only in the old file and an added
/// one only in the new, so "line 32" on its own names two different lines. Diffs
/// spell this `L32` and `R32`, and so does this.
enum DiffSide {
  /// The file as it was — a removed line, or the left half of a context line.
  before('L'),

  /// The file as it will be — an added line.
  after('R');

  const DiffSide(this.mark);

  /// The letter a diff puts in front of the number.
  final String mark;
}

/// One remark the user left on one line of a diff.
///
/// Held for the session rather than written anywhere: this is a note on the way
/// to asking the assistant for a change, not a review that outlives the app. It
/// says so — "Local comment" — so nobody waits for a teammate to answer it.
@immutable
class ReviewComment {
  const ReviewComment({
    required this.path,
    required this.side,
    required this.line,
    required this.text,
    this.code = '',
  });

  /// The file, relative to the repository root.
  final String path;

  final DiffSide side;

  /// The line's number in the file [side] names.
  final int line;

  /// What the user asked for.
  final String text;

  /// The line itself, as it read when the comment was left.
  ///
  /// Carried into the prompt because a number alone is a fragile way to point:
  /// the assistant reads the file *now*, and by then an edit may have moved
  /// line 32. The text is what makes the reference survive that.
  final String code;

  /// `R32` — how a diff names this line.
  String get anchor => '${side.mark}$line';

  /// Whether this is a remark about the same line as [other], whatever either
  /// of them says.
  bool sameLineAs(ReviewComment other) =>
      other.path == path && other.side == side && other.line == line;
}

/// Where a comment on [row] would go, or null for a row that isn't a line of
/// the file — Git's own asides carry no number to point at.
///
/// The new file wins when a line is in both: a context line is the same line on
/// either side, and the number worth quoting is the one the file has now.
({DiffSide side, int line})? commentAnchorFor(DiffRow row) {
  if (row.kind == DiffRowKind.note) return null;
  final after = row.newLine;
  if (after != null) return (side: DiffSide.after, line: after);
  final before = row.oldLine;
  if (before != null) return (side: DiffSide.before, line: before);
  return null;
}

/// What has been left on one file, for the diff being drawn.
///
/// A function over the list rather than a method on the notifier: a widget has
/// to *watch* the comments to redraw when one is left, and watching a notifier
/// is watching the object, not what it holds — the card would appear only once
/// something else rebuilt the diff.
List<ReviewComment> commentsForFile(
  List<ReviewComment> comments,
  String path,
) => [
  for (final comment in comments)
    if (comment.path == path) comment,
];

/// The message that hands [comments] to the assistant.
///
/// Pure so the words are testable, and because they are the whole feature: a
/// comment nobody can act on is a note to self.
///
/// The lines are quoted alongside their numbers — see [ReviewComment.code] —
/// and the assistant is told to read the file first, because by the time it
/// does, its own earlier edit may have moved everything below line 32.
String commentsPrompt(List<ReviewComment> comments) {
  if (comments.isEmpty) return '';
  final count = comments.length;
  final body = [
    for (final comment in comments)
      '- ${comment.path}:${comment.line}'
          '${comment.code.isEmpty ? '' : '  `${comment.code}`'}\n'
          '  ${comment.text.trim()}',
  ].join('\n');
  return 'I have left $count comment${count == 1 ? '' : 's'} on the changes in '
      'this project.\n\n$body\n\n'
      'Read each file around the line quoted before you change anything — the '
      'numbers are from the diff I was looking at, and your own edits will move '
      'them. Tell me what you changed.';
}
