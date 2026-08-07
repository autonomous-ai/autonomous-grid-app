import 'review_snapshot.dart';

/// What the toolbar's one bright button does when it is pressed.
///
/// Derived from the repository rather than fixed, because the obvious next step
/// genuinely differs: with files ticked it is a commit, with none it is ticking
/// them first, and in a scope nothing can be ticked in it is sending what is
/// already committed.
///
/// A button that named the *state* instead — "Nothing ticked", greyed out — left
/// the user holding a dead control with the only way forward hidden inside a
/// caret menu, which is the opposite of what §5 asks of every state.
enum CommitAction {
  /// Commit the files that are ticked.
  commit('Commit'),

  /// Nothing is ticked yet: tick every file the list is showing, then commit.
  commitAll('Commit all'),

  /// Nothing here can be committed, but commits are waiting to be sent.
  push('Push'),

  /// Neither is possible, so the button doesn't belong on screen at all.
  none('');

  const CommitAction(this.label);

  /// What the button says. Always a verb — this is the only place the words are
  /// written.
  final String label;
}

/// The action [snapshot] leaves open, in the order a person would reach for
/// them.
///
/// Committing outranks pushing: work that is only in the working tree is the
/// change the user is looking at, while an unpushed commit is already safe on
/// this computer. Whichever loses stays available in the button's menu.
CommitAction commitActionFor(ReviewSnapshot snapshot) {
  if (snapshot.scope.canStage) {
    if (snapshot.staged.isNotEmpty) return CommitAction.commit;
    if (snapshot.files.isNotEmpty) return CommitAction.commitAll;
  }
  // A detached HEAD has no branch to push, and Git refuses it — offering the
  // action anyway would be a promise the repository can't keep.
  if (snapshot.ahead > 0 && !snapshot.detached) return CommitAction.push;
  return CommitAction.none;
}
