import 'package:flutter/foundation.dart';
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

/// Everything about *how* a diff is drawn that the user can change, held
/// together because they are read together and one menu sets them all.
@immutable
class DiffViewPrefs {
  const DiffViewPrefs({
    this.layout = DiffLayout.unified,
    this.wrap = true,
    this.ignoreWhitespace = false,
    this.collapsed = false,
  });

  final DiffLayout layout;

  /// Long lines fold onto the next row rather than running off the side.
  ///
  /// On by default, and the reason the diff has no horizontal scrollbar: the
  /// panel is 420–760px wide, and a line you have to drag sideways to finish
  /// reading is one you don't finish reading.
  final bool wrap;

  /// Ask Git to ignore lines that differ only in spacing — a re-indented file
  /// otherwise reads as rewritten from top to bottom.
  final bool ignoreWhitespace;

  /// Every changed section folded to its heading, so a long file can be read as
  /// a table of contents first.
  final bool collapsed;

  DiffViewPrefs copyWith({
    DiffLayout? layout,
    bool? wrap,
    bool? ignoreWhitespace,
    bool? collapsed,
  }) => DiffViewPrefs(
    layout: layout ?? this.layout,
    wrap: wrap ?? this.wrap,
    ignoreWhitespace: ignoreWhitespace ?? this.ignoreWhitespace,
    collapsed: collapsed ?? this.collapsed,
  );
}

/// How diffs are drawn, everywhere in the app.
///
/// One setting rather than one per folder: this is a preference about reading
/// diffs, not a fact about a repository, and a user who wants two columns wants
/// them in the next project too.
final diffViewPrefsProvider =
    NotifierProvider<DiffViewPrefsController, DiffViewPrefs>(
      DiffViewPrefsController.new,
    );

class DiffViewPrefsController extends Notifier<DiffViewPrefs> {
  @override
  DiffViewPrefs build() => const DiffViewPrefs();

  void toggleLayout() => state = state.copyWith(layout: state.layout.other);

  void toggleWrap() => state = state.copyWith(wrap: !state.wrap);

  void toggleWhitespace() =>
      state = state.copyWith(ignoreWhitespace: !state.ignoreWhitespace);

  /// Fold or unfold every section at once. A section opened by hand afterwards
  /// wins over this — see `reviewOpenHunksProvider`.
  void toggleCollapsed() => state = state.copyWith(collapsed: !state.collapsed);
}

/// The sections the user has opened or closed by hand since the last "collapse
/// all", per file.
///
/// A set of *exceptions* rather than the truth: "collapse all" is one flag, and
/// a fold opened afterwards has to survive without turning that flag off for
/// every other section too. Cleared whenever the flag is thrown, which is what
/// makes the button say what it does.
final reviewOpenHunksProvider =
    NotifierProvider.family<ReviewOpenHunks, Set<int>, String>(
      ReviewOpenHunks.new,
    );

class ReviewOpenHunks extends Notifier<Set<int>> {
  ReviewOpenHunks(this.path);

  /// The file whose sections these are — the family argument.
  final String path;

  @override
  Set<int> build() {
    // Thrown by the menu, so the exceptions it collected stop applying.
    ref.listen(diffViewPrefsProvider.select((p) => p.collapsed), (_, _) {
      state = const {};
    });
    return const {};
  }

  void toggle(int index) => state = state.contains(index)
      ? Set.unmodifiable({...state}..remove(index))
      : Set.unmodifiable({...state, index});
}

/// Whether the section at [index] is open, given the standing choice and the
/// exceptions since.
bool hunkIsOpen({
  required bool collapsedAll,
  required Set<int> exceptions,
  required int index,
}) => exceptions.contains(index) ? collapsedAll : !collapsedAll;
