/// Why a Git command the Review screen ran didn't produce an answer.
///
/// Two cases, because they lead somewhere different: one is about this
/// computer and is fixed on the Git screen, the other is about this repository
/// and is explained by [friendlyGitFailure] in the user's own terms.
sealed class ReviewFailure {
  const ReviewFailure();
}

/// No Git on this computer, or it never answered. The screen offers to install
/// one rather than blaming the folder.
class ReviewNoGit extends ReviewFailure {
  const ReviewNoGit();
}

/// Git ran and refused. [raw] is its own words — kept whole for the log, and
/// handed to `friendlyGitFailure` for the sentence the user reads.
class ReviewGitRefused extends ReviewFailure {
  const ReviewGitRefused(this.raw);
  final String raw;
}
