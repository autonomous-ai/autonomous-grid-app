import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What one Files tab is looking at: which folders are open, which file is
/// showing, and what the filter box says.
@immutable
class FilesBrowserState {
  FilesBrowserState({
    Set<String> expanded = const {},
    this.root,
    this.selected,
    this.query = '',
    this.showSource = false,
    this.showTree = true,
  }) : expanded = Set.unmodifiable(expanded);

  /// The project folder this tab was last pointed at, or null before it has been
  /// pointed anywhere.
  ///
  /// Held here so that re-rooting can be *noticed*. A Files tab is rooted at
  /// whichever project the open chat belongs to, which is not a decision the tab
  /// made and can change under it — see [FilesBrowser.showRoot].
  final String? root;

  /// Absolute paths of the folders the user has opened. The root's own children
  /// are always listed; this is everything expanded beneath them.
  final Set<String> expanded;

  /// The file on screen, or null before the user has picked one.
  final String? selected;

  final String query;

  /// Whether Markdown is shown as the text it was written in rather than as the
  /// document it describes. Only Markdown has the two forms, so this means
  /// nothing for every other file.
  ///
  /// Rendered is the resting state: a `.md` is prose, and prose read as source
  /// is prose with the punctuation left in. It rides on the tab rather than on
  /// the file, so a reader who wants the raw text keeps getting it as they click
  /// down a folder of documents.
  final bool showSource;

  /// Whether the tree of folders is beside the file.
  ///
  /// Out by default — it is how you get anywhere from here. Hiding it is for
  /// reading: a panel docked at 420px has little enough width without a third of
  /// it going to a column you have finished with for now.
  final bool showTree;

  FilesBrowserState copyWith({
    Set<String>? expanded,
    String? root,
    String? selected,
    String? query,
    bool? showSource,
    bool? showTree,
  }) => FilesBrowserState(
    expanded: expanded ?? this.expanded,
    root: root ?? this.root,
    selected: selected ?? this.selected,
    query: query ?? this.query,
    showSource: showSource ?? this.showSource,
    showTree: showTree ?? this.showTree,
  );
}

/// One of these per Files tab, keyed by the tab's id.
///
/// Per tab rather than per panel: two Files tabs are two places in the same
/// project, and sharing one selection between them would make the second tab
/// pointless — clicking a file in either would move both.
final filesBrowserProvider =
    NotifierProvider.family<FilesBrowser, FilesBrowserState, String>(
      FilesBrowser.new,
    );

class FilesBrowser extends Notifier<FilesBrowserState> {
  FilesBrowser(this.tabId);

  /// The tab this belongs to — the family argument, which is what keeps one
  /// tab's open folders and selection out of another's.
  final String tabId;

  @override
  FilesBrowserState build() => FilesBrowserState();

  void toggleFolder(String path) {
    final expanded = {...state.expanded};
    // remove() reports whether it was open; if it wasn't, open it.
    if (!expanded.remove(path)) expanded.add(path);
    state = state.copyWith(expanded: expanded);
  }

  void select(String path) => state = state.copyWith(selected: path);

  /// Point this tab at [root], forgetting the last project if it was a different
  /// one.
  ///
  /// A tab is rooted at the project the open chat belongs to, so switching to a
  /// chat in another project re-roots it underneath the user. Nothing it was
  /// holding survives that: the tree would come back showing this project with
  /// the other one's folders opened under it, and a file out of the other
  /// project still on screen beside them.
  ///
  /// Called on every rebuild of the tab, so the ordinary case — moving between
  /// chats inside one project — has to cost nothing, which is what the first
  /// line is for. A tab whose file was chosen before it first drew ([reveal])
  /// arrives already carrying its root, so this leaves it alone too.
  void showRoot(String root) {
    if (state.root == root) return;
    // The *place* resets; how the tab is set up to read does not. Hiding the
    // tree and reading Markdown as source are choices about this tab, and a user
    // who hid the tree to read a document did not ask for it back by opening a
    // chat in another project.
    state = FilesBrowserState(
      root: root,
      showSource: state.showSource,
      showTree: state.showTree,
    );
  }

  /// Show [path], with every folder between [root] and it already open.
  ///
  /// For a tab that has just been created to hold one file: selecting alone
  /// would put the file on screen with a tree collapsed to the project's top
  /// level beside it, so the panel would be showing something it couldn't say
  /// the whereabouts of.
  void reveal({required String path, required String root}) {
    final expanded = {...state.expanded};
    // Every ancestor, walked down from the root rather than up from the file:
    // the root's own separator is whatever the platform wrote, and re-joining
    // segments would lose it.
    var cut = path.indexOf(RegExp(r'[/\\]'), root.length + 1);
    while (cut > 0) {
      expanded.add(path.substring(0, cut));
      cut = path.indexOf(RegExp(r'[/\\]'), cut + 1);
    }
    // The root goes in with it. This runs before the tab has drawn once, and
    // without it the tab's first frame would see a root it had never been told
    // about, call that a re-rooting, and throw away the file it was opened to
    // show.
    state = state.copyWith(expanded: expanded, root: root, selected: path);
  }

  void setQuery(String query) => state = state.copyWith(query: query);

  void toggleSource() => state = state.copyWith(showSource: !state.showSource);

  void toggleTree() => state = state.copyWith(showTree: !state.showTree);

  void collapseAll() => state = state.copyWith(expanded: const {});
}
