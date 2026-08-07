import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'review_comment.dart';

/// The remarks left on one folder's diff, in the order they were written.
///
/// Per folder, like everything else on this screen: a comment names a line in a
/// file in *this* repository, and carrying it into the next project would point
/// at a line that isn't there.
///
/// Session-lived on purpose. These are a request in the making — the moment they
/// are handed to the assistant they have done their job, which is why sending
/// them clears them.
final reviewCommentsProvider =
    NotifierProvider.family<ReviewComments, List<ReviewComment>, String>(
      ReviewComments.new,
    );

class ReviewComments extends Notifier<List<ReviewComment>> {
  ReviewComments(this.folder);

  /// The folder these belong to — the family argument.
  final String folder;

  @override
  List<ReviewComment> build() => const [];

  /// Leave [comment], replacing whatever was on that line.
  ///
  /// One per line rather than a thread: there is nobody to reply to, and two
  /// remarks on the same line reach the assistant as one instruction anyway —
  /// better the user rewrites theirs than discovers the two were merged.
  void add(ReviewComment comment) => state = List.unmodifiable([
    for (final existing in state)
      if (!existing.sameLineAs(comment)) existing,
    comment,
  ]);

  /// Take back the comment on the line [comment] names.
  void remove(ReviewComment comment) => state = List.unmodifiable([
    for (final existing in state)
      if (!existing.sameLineAs(comment)) existing,
  ]);

  /// After they have been sent — see [reviewCommentsProvider].
  void clear() => state = const [];
}

/// The line whose comment box is open, or null when none is.
///
/// One at a time, and its own provider rather than state inside the diff: the
/// list is lazy, so the row holding an open box can be scrolled out of the tree
/// and rebuilt — and a half-typed remark must not be lost to that.
final reviewCommentDraftProvider =
    NotifierProvider.family<ReviewCommentDraft, CommentDraft?, String>(
      ReviewCommentDraft.new,
    );

class ReviewCommentDraft extends Notifier<CommentDraft?> {
  ReviewCommentDraft(this.folder);

  /// The folder being reviewed — the family argument.
  final String folder;

  @override
  CommentDraft? build() => null;

  void open(CommentDraft draft) => state = draft;

  void close() => state = null;
}

/// Which line is being written about, and what it says.
class CommentDraft {
  const CommentDraft({
    required this.path,
    required this.side,
    required this.line,
    required this.code,
    this.text = '',
  });

  final String path;
  final DiffSide side;
  final int line;

  /// The line as drawn, carried into the comment — see [ReviewComment.code].
  final String code;

  /// What was already there when the box opened: empty for a new remark, the
  /// old words when an existing one is being rewritten.
  final String text;

  /// Whether this draft is the box for the line [comment] is on.
  bool isFor(ReviewComment comment) =>
      comment.path == path && comment.side == side && comment.line == line;

  ReviewComment toComment(String written) => ReviewComment(
    path: path,
    side: side,
    line: line,
    text: written,
    code: code,
  );
}
