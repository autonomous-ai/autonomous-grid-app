import 'review_base.dart';
import 'review_file.dart';

/// Everything the Review screen knows about a repository at one moment.
///
/// Taken in one pass rather than read field by field: the branch, its remote
/// and the file list all come from the same instant, so the header can never
/// name one branch while the list shows another's changes.
class ReviewSnapshot {
  const ReviewSnapshot({
    required this.root,
    required this.branch,
    required this.base,
    required this.files,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.hasCommits = true,
    this.detached = false,
  });

  /// The repository's top folder — which may be *above* the project's folder,
  /// when the user added a subdirectory of a repository they already had.
  final String root;

  /// The branch name, or the commit's short name when [detached].
  final String branch;

  /// Which comparison [files] answers.
  final ReviewBase base;

  final List<ReviewFile> files;

  /// The remote branch this one tracks (`origin/main`), or null when it tracks
  /// none — which is what makes the first push need `--set-upstream`.
  final String? upstream;

  /// Commits this branch has that [upstream] doesn't, and the reverse.
  final int ahead;
  final int behind;

  /// False in a repository whose first commit hasn't been made. `HEAD` doesn't
  /// resolve there, so several commands that look unconditional are errors.
  final bool hasCommits;

  /// The repository is on a commit rather than a branch. Committing here is
  /// how work gets lost, so the screen says so.
  final bool detached;

  int get added => totalAdded(files);
  int get removed => totalRemoved(files);

  /// The files a commit would carry right now.
  List<ReviewFile> get staged => [
    for (final file in files)
      if (file.staged) file,
  ];

  bool get isEmpty => files.isEmpty;
}
