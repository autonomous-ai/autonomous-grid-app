/// Which set of changes the Review surface is showing.
///
/// Six, because they are six genuinely different questions — and each maps to a
/// different pair of Git commands, not to a filter over one answer:
///
/// * [LastTurnChanges] — what the assistant just did. The narrowest, and the
///   one a user watching an agent work actually wants.
/// * [UncommittedChanges] — everything not in a commit yet, staged or not.
/// * [UnstagedChanges] / [StagedChanges] — the two halves of that, for anyone
///   composing a commit out of part of their work.
/// * [CommittedChange] — one commit that has already been made.
/// * [BranchAgainst] — everything this branch adds on top of another one.
sealed class ReviewScope {
  const ReviewScope();

  /// The name on the button that opens the scope menu. Short — it sits in a
  /// toolbar, next to the counts.
  String get label => switch (this) {
    LastTurnChanges() => 'Last turn',
    UncommittedChanges() => 'Uncommitted',
    UnstagedChanges() => 'Unstaged',
    StagedChanges() => 'Staged',
    CommittedChange(:final commit) => commit.shortSha,
    BranchAgainst(:final ref) => 'vs $ref',
  };

  /// The sentence the surface puts under an empty list, so "nothing here" says
  /// *nothing of what*.
  String get emptyLine => switch (this) {
    LastTurnChanges() => "The assistant hasn't changed any files this turn.",
    UncommittedChanges() =>
      'Every file here matches the last commit. Ask the assistant to make a '
          'change and it will show up here.',
    UnstagedChanges() =>
      'Nothing is waiting to be included — every change is already ticked.',
    StagedChanges() => 'No files are ticked for the next commit yet.',
    CommittedChange() => 'This commit changed no files.',
    BranchAgainst(:final ref) => 'This branch has nothing $ref does not.',
  };

  /// Whether ticking files on or off means anything here.
  ///
  /// Only where there is still an index to move things into or out of: what a
  /// commit or a branch contains was decided when it was made, and a tick there
  /// would be a control that does nothing.
  bool get canStage => switch (this) {
    LastTurnChanges() || UncommittedChanges() || UnstagedChanges() => true,
    StagedChanges() => true,
    CommittedChange() || BranchAgainst() => false,
  };

  /// Whether files Git has never been told about belong in this list. They are
  /// part of "what is not committed", but they are in no commit, no index and
  /// no branch.
  bool get showsUntracked => switch (this) {
    LastTurnChanges() || UncommittedChanges() || UnstagedChanges() => true,
    StagedChanges() || CommittedChange() || BranchAgainst() => false,
  };
}

/// The files the assistant touched in its most recent turn — a filter over the
/// uncommitted changes, since that is where a just-made edit lives.
class LastTurnChanges extends ReviewScope {
  const LastTurnChanges();

  @override
  bool operator ==(Object other) => other is LastTurnChanges;

  @override
  int get hashCode => 1;
}

/// Working tree and index against the last commit — the default, because it is
/// everything that would be lost if the folder were thrown away.
class UncommittedChanges extends ReviewScope {
  const UncommittedChanges();

  @override
  bool operator ==(Object other) => other is UncommittedChanges;

  @override
  int get hashCode => 2;
}

/// Changes not yet ticked for the next commit — `git diff` with no arguments.
class UnstagedChanges extends ReviewScope {
  const UnstagedChanges();

  @override
  bool operator ==(Object other) => other is UnstagedChanges;

  @override
  int get hashCode => 3;
}

/// What the next commit would carry — `git diff --cached`.
class StagedChanges extends ReviewScope {
  const StagedChanges();

  @override
  bool operator ==(Object other) => other is StagedChanges;

  @override
  int get hashCode => 4;
}

/// One commit that has already been made.
class CommittedChange extends ReviewScope {
  const CommittedChange(this.commit);

  final CommitRef commit;

  @override
  bool operator ==(Object other) =>
      other is CommittedChange && other.commit.sha == commit.sha;

  @override
  int get hashCode => commit.sha.hashCode;
}

/// Commits this branch has that [ref] doesn't — the diff a pull request would
/// show, measured from where the two branches parted (`merge-base`), so commits
/// that landed on [ref] afterwards don't read as this branch removing them.
class BranchAgainst extends ReviewScope {
  const BranchAgainst(this.ref);

  /// A branch name Git can resolve: `origin/main`, `main`, a tag, a commit.
  final String ref;

  @override
  bool operator ==(Object other) => other is BranchAgainst && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;
}

/// One commit in the "Committed" list: enough to recognise it by.
class CommitRef {
  const CommitRef({
    required this.sha,
    required this.subject,
    required this.author,
    required this.when,
  });

  /// The full hash — what Git is asked for; never shown whole.
  final String sha;

  /// The commit's first line.
  final String subject;
  final String author;

  /// Git's own relative time ("2 hours ago"), which is what a person reads a
  /// commit list by. Taken from Git rather than computed here so it can't drift
  /// from what `git log` says.
  final String when;

  /// The seven characters everyone actually quotes.
  String get shortSha => sha.length <= 7 ? sha : sha.substring(0, 7);
}
