/// What happened to a file in the change set being reviewed.
enum ReviewFileKind {
  /// Added and already staged (`git add`ed), or added by the branch.
  added,
  modified,
  deleted,

  /// Moved, with [ReviewFile.oldPath] naming where it came from.
  renamed,

  /// A file Git has never been told about. Its own case, not [added]: nothing
  /// will be committed unless the user stages it first, and the screen has to
  /// be able to say so.
  untracked,

  /// Left half-merged by a conflict. Shown, never staged from here — resolving
  /// a merge is not something this screen can honestly offer.
  conflicted,
}

/// One file in the change set: what happened to it and how much of it changed.
class ReviewFile {
  const ReviewFile({
    required this.path,
    required this.kind,
    this.oldPath,
    this.staged = false,
    this.unstaged = false,
    this.added = 0,
    this.removed = 0,
    this.binary = false,
  });

  /// Relative to the repository root, forward slashes — Git's own form, which
  /// is also what every command here takes back.
  final String path;

  /// Where a [ReviewFileKind.renamed] file came from; null otherwise.
  final String? oldPath;

  final ReviewFileKind kind;

  /// Whether this file's change is in the index, so a commit would include it.
  final bool staged;

  /// Whether it *also* differs from the index — the half of a change that is
  /// only on disk. Both can be true at once: a file staged and then edited
  /// again is in the next commit *and* has something left over.
  final bool unstaged;

  /// Lines added and removed. Both zero for a [binary] file, where counting
  /// lines means nothing.
  final int added;
  final int removed;
  final bool binary;

  /// The file's own name, for a compact label.
  String get name => path.split('/').last;

  /// The folder holding it, relative to the repository root ('' at the top).
  String get folder {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }

  ReviewFile copyWith({int? added, int? removed, bool? binary, bool? staged}) =>
      ReviewFile(
        path: path,
        kind: kind,
        oldPath: oldPath,
        staged: staged ?? this.staged,
        unstaged: unstaged,
        added: added ?? this.added,
        removed: removed ?? this.removed,
        binary: binary ?? this.binary,
      );
}

/// Lines added across [files] — the `+16,805` half of the toolbar's count.
int totalAdded(List<ReviewFile> files) =>
    files.fold(0, (sum, file) => sum + file.added);

/// Lines removed across [files].
int totalRemoved(List<ReviewFile> files) =>
    files.fold(0, (sum, file) => sum + file.removed);
