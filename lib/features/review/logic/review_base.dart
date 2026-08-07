/// Which set of changes the Review screen is showing.
///
/// Two genuinely different questions, so they are two types rather than a flag:
/// *what have I not committed yet* (what an agent just did to the folder) and
/// *what does this branch add on top of another one* (what a pull request would
/// contain). The commands, the file list and the copy all differ between them.
sealed class ReviewBase {
  const ReviewBase();

  /// The heading the screen puts over the file list.
  String get label => switch (this) {
    UncommittedChanges() => 'Uncommitted changes',
    BranchAgainst(:final ref) => 'This branch vs $ref',
  };

  /// The sentence under it — what the list is, in the user's terms.
  String get description => switch (this) {
    UncommittedChanges() =>
      'Everything changed in this folder that you have not committed yet.',
    BranchAgainst(:final ref) =>
      'What this branch has added since it left $ref. Changes you have not '
          'committed are not in this list.',
  };
}

/// What to put in the composer when the user asks the assistant to review this
/// change.
///
/// Says which changes to look at and leaves the agent to read them with its own
/// tools: pasting a sixteen-thousand-line diff into a message would blow the
/// context window and cost the user's grid for the privilege.
///
/// Pure so the words are testable — this is the one place they are written.
String askAgentPrompt(ReviewBase base) => switch (base) {
  UncommittedChanges() =>
    'Review the changes I have not committed yet in this project — run '
        '`git status` and `git diff HEAD` to read them. Tell me what looks '
        'wrong, risky or unfinished, and what you would change. Do not edit '
        'anything yet.',
  BranchAgainst(:final ref) =>
    'Review what this branch changes compared with $ref — run '
        '`git diff $ref...HEAD` to read it. Tell me what looks wrong, risky '
        'or unfinished, and what you would change. Do not edit anything yet.',
};

/// Working tree and staged changes against the last commit — the default,
/// because it is what the assistant just did to the user's files.
class UncommittedChanges extends ReviewBase {
  const UncommittedChanges();

  @override
  bool operator ==(Object other) => other is UncommittedChanges;

  @override
  int get hashCode => 0;
}

/// Commits this branch has that [ref] doesn't — the diff a pull request would
/// show, measured from where the two branches parted (`merge-base`), so
/// commits that landed on [ref] afterwards don't read as this branch removing
/// them.
class BranchAgainst extends ReviewBase {
  const BranchAgainst(this.ref);

  /// A branch name Git can resolve: `origin/main`, `main`, a tag, a commit.
  final String ref;

  @override
  bool operator ==(Object other) => other is BranchAgainst && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;
}
