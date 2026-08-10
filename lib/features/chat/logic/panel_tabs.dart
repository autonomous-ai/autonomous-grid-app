import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../files/logic/files_browser.dart';
import '../../terminal/logic/terminal_sessions_controller.dart';
import 'bottom_panel.dart';
import 'preview_panel.dart';

/// One of the two panels around the conversation.
///
/// They hold the same kinds of surface and none of the same contents: a
/// terminal opened beside the chat and one opened under it are two terminals,
/// the way two windows of the same app are two windows.
enum PanelHost {
  /// Beside the conversation, on the right.
  preview,

  /// Under the conversation, spanning the whole pane.
  bottom,
}

/// A surface a panel can open, and everything the app needs to name it: the
/// launcher row, the tab, and the tooltip all read from here.
///
/// Only what is built. A browser and a side chat were listed here while they
/// were still `TODO — <name>`: a menu that opens onto an empty screen is a
/// worse answer than a shorter menu, and it costs the user the click to find
/// that out.
///
/// The shortcuts are labels, not bindings — nothing listens for them yet. They
/// become real with the surfaces they name.
enum PanelFeature {
  review(LucideIcons.fileCheck, 'Review', shortcut: '⌃⇧G'),
  terminal(LucideIcons.squareTerminal, 'Terminal'),
  files(LucideIcons.folder, 'Files', shortcut: '⌘P');

  const PanelFeature(this.icon, this.label, {this.shortcut});

  final IconData icon;
  final String label;
  final String? shortcut;
}

/// One open tab.
///
/// [title] is held rather than derived from [feature] because a second Review
/// is "Review 2": the number belongs to this tab and must not move when a
/// tab beside it closes.
@immutable
class PanelTab {
  const PanelTab({
    required this.id,
    required this.feature,
    required this.title,
  });

  final String id;
  final PanelFeature feature;
  final String title;
}

/// What one panel is showing.
@immutable
class PanelTabsState {
  PanelTabsState({List<PanelTab> tabs = const [], this.activeId})
    : tabs = List.unmodifiable(tabs);

  final List<PanelTab> tabs;

  /// The tab whose body fills the panel.
  ///
  /// Null only while [tabs] is empty, and that is what puts the launcher on
  /// screen. With tabs open there is always one selected: "+" opens a menu over
  /// the panel rather than replacing what you were reading with a chooser.
  final String? activeId;

  PanelTab? get active {
    for (final tab in tabs) {
      if (tab.id == activeId) return tab;
    }
    return null;
  }
}

/// The tabs of one panel. Per host, because the two panels are two places to
/// work: opening a terminal beside the conversation must not change what is
/// open under it.
final panelTabsProvider =
    NotifierProvider.family<PanelTabs, PanelTabsState, PanelHost>(
      PanelTabs.new,
    );

class PanelTabs extends Notifier<PanelTabsState> {
  PanelTabs(this.host);

  /// The panel these tabs belong to — the family argument.
  final PanelHost host;

  /// Ids come from a counter rather than the clock: two tabs opened in the same
  /// microsecond would collide, and a counter is the same every run, which a
  /// test can assert against. Prefixed by the panel so the two counters can't
  /// hand out the same id to a tab in each.
  int _seq = 0;

  @override
  PanelTabsState build() => PanelTabsState();

  /// Opens [feature] in a new tab and shows it.
  ///
  /// Always a new tab, never a jump to an existing one — two terminals in two
  /// directories is the normal case, not a mistake. [reveal] is the other verb,
  /// for the callers that mean "show me this".
  ///
  /// Opens the panel too: every way in here is somebody asking to *see*
  /// something, and a tab opened behind a closed panel is a click that did
  /// nothing.
  ///
  /// Returns the new tab's id, for the callers that have something to put in it:
  /// a feature's per-tab state is keyed by that id, so "open a Files tab already
  /// showing this file" needs it before the tab has drawn once.
  String open(PanelFeature feature) {
    final tab = PanelTab(
      id: '${host.name}-tab-${++_seq}',
      feature: feature,
      title: _titleFor(feature),
    );
    state = PanelTabsState(tabs: [...state.tabs, tab], activeId: tab.id);
    _openPanel();
    return tab.id;
  }

  /// Brings [feature] to the front, opening a tab for it only if none is.
  ///
  /// What a keyboard shortcut wants: ⌃⇧G pressed three times should show
  /// Review, not stack three Reviews. The launcher and the "+" menu still use
  /// [open], because there the user picked a row meaning "another one".
  void reveal(PanelFeature feature) {
    for (final tab in state.tabs) {
      if (tab.feature != feature) continue;
      select(tab.id);
      _openPanel();
      return;
    }
    open(feature);
  }

  void select(String id) =>
      state = PanelTabsState(tabs: state.tabs, activeId: id);

  /// Closes one tab, and the whole panel with it if it was the last.
  ///
  /// A panel left standing on an empty tab strip is a strip of chrome with
  /// nothing under it; the user closed the last thing they were looking at, so
  /// the answer to "what now" is the conversation at full width.
  void close(String id) {
    final index = state.tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;

    // Whatever the tab was holding goes with it. Done here rather than by
    // something watching the tab list, because a watcher only runs while
    // somebody is looking at it — and this has to happen even if the user
    // closes a tab on their way out of Chat.
    //
    // A shell has to be killed. Files only has state — but that state is keyed
    // by this id and nothing else will ever ask for it again, so left alone it
    // is a set of open folder paths per Files tab the session ever had.
    ref.read(terminalSessionsProvider.notifier).endSession(id);
    ref.invalidate(filesBrowserProvider(id));

    final rest = [...state.tabs]..removeAt(index);
    if (rest.isEmpty) {
      state = PanelTabsState();
      _closePanel();
      return;
    }

    // Closing the tab you're on hands you the one to its left, the way every
    // editor does it — the tab that took its place on screen would otherwise
    // arrive under the pointer and catch the next click.
    final activeId = state.activeId == id
        ? rest[index == 0 ? 0 : index - 1].id
        : state.activeId;
    state = PanelTabsState(tabs: rest, activeId: activeId);
  }

  void _openPanel() => switch (host) {
    PanelHost.preview => ref.read(previewPanelOpenProvider.notifier).open(),
    PanelHost.bottom => ref.read(bottomPanelOpenProvider.notifier).open(),
  };

  void _closePanel() => switch (host) {
    PanelHost.preview => ref.read(previewPanelOpenProvider.notifier).close(),
    PanelHost.bottom => ref.read(bottomPanelOpenProvider.notifier).close(),
  };

  /// "Review", then "Review 2" — the lowest number not currently on screen, so
  /// closing one and opening another can't produce two tabs with one name.
  String _titleFor(PanelFeature feature) {
    final taken = state.tabs.map((tab) => tab.title).toSet();
    if (!taken.contains(feature.label)) return feature.label;
    var n = 2;
    while (taken.contains('${feature.label} $n')) {
      n++;
    }
    return '${feature.label} $n';
  }
}
