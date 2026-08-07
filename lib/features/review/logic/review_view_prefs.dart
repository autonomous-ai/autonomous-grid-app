import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the changed-file list is beside the diff.
///
/// Per folder, like the rest of what this surface remembers: which project you
/// were reading a file in is the thing worth coming back to.
///
/// Out by default — it is how you get from one file to the next. Hiding it is
/// for reading, exactly as the Files tab's tree is: a panel docked at 420px has
/// little enough width without a third of it going to a list you have finished
/// with for now.
final reviewFilesShownProvider =
    NotifierProvider.family<ReviewFilesShown, bool, String>(
      ReviewFilesShown.new,
    );

class ReviewFilesShown extends Notifier<bool> {
  ReviewFilesShown(this.folder);

  /// The folder being reviewed — the family argument.
  final String folder;

  @override
  bool build() => true;

  void toggle() => state = !state;
}

/// The two ways to read a diff.
enum DiffLayout {
  /// One column: removed lines above the added ones that replaced them. Reads
  /// like a story and survives a narrow panel.
  unified,

  /// Two columns, before and after, lines paired across. Better for a change
  /// *within* a line — and unreadable below [kSplitDiffFrom].
  split;

  /// What the button that switches to the *other* one says. Names the click,
  /// not the state: a one-button switch whose icon flips is otherwise a guess.
  String get switchLabel => switch (this) {
    unified => 'Switch to side-by-side diff',
    split => 'Switch to unified diff',
  };

  DiffLayout get other => switch (this) {
    unified => split,
    split => unified,
  };
}

/// The narrowest pane worth splitting in two.
///
/// Below this each column is under 280px — narrower than the diff was in the
/// panel's *narrow* layout, where the app already decided a diff isn't worth
/// reading. The toggle is not offered under it, and a choice made on a wide
/// window quietly draws unified until there is room again, rather than
/// shredding every line into three.
const double kSplitDiffFrom = 620;

/// How diffs are drawn, everywhere in the app.
///
/// One setting rather than one per folder: this is a preference about reading
/// diffs, not a fact about a repository, and a user who wants two columns wants
/// them in the next project too.
final reviewDiffLayoutProvider = NotifierProvider<ReviewDiffLayout, DiffLayout>(
  ReviewDiffLayout.new,
);

class ReviewDiffLayout extends Notifier<DiffLayout> {
  @override
  DiffLayout build() => DiffLayout.unified;

  void toggle() => state = state.other;
}
