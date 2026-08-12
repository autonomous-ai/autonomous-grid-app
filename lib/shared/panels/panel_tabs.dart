import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/chat/logic/composer_context.dart';
import '../../features/files/logic/files_browser.dart';
import '../../features/terminal/logic/terminal_sessions_controller.dart';

/// One of the panels the app can open beside — or under — what you are working
/// on.
///
/// They hold the same kinds of surface and none of the same contents: a
/// terminal opened beside the chat and one opened under it are two terminals,
/// the way two windows of the same app are two windows.
///
/// This lives in `shared/` rather than in `chat/` because Code opens the same
/// panel beside a project's conversation. Two lookalike panels with their own
/// habits was the alternative, and that is exactly what one of them being a
/// copy of the other produced: plain text tabs, no launcher, no second
/// terminal, and a close button in a place the chat's panel doesn't have one.
enum PanelHost {
  /// Beside the conversation, on the right.
  preview,

  /// Under the conversation, spanning the whole pane.
  bottom,

  /// Beside a Code project's conversation, rooted at that project's copy on
  /// this computer rather than at the chat's workspace.
  code,
}

/// A surface a panel can open, and everything the app needs to name it: the
/// launcher row, the tab, and the tooltip all read from here.
///
/// Only what is built. A browser and a side chat were listed here while they
/// were still `TODO — <name>`: a menu that opens onto an empty screen is a
/// worse answer than a shorter menu, and it costs the user the click to find
/// that out.
enum PanelFeature {
  review(LucideIcons.fileCheck, 'Review', shortcut: '⌃⇧G'),
  terminal(LucideIcons.squareTerminal, 'Terminal', shortcut: '⌃`'),
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

/// Whether a panel is open.
///
/// Deliberately not persisted, and deliberately not per-chat or per-project: a
/// panel is a place to *do* something next to whatever you are saying, so it
/// stays open while you move between conversations and starts closed in a
/// window you have just opened.
final panelOpenProvider = NotifierProvider.family<PanelOpen, bool, PanelHost>(
  PanelOpen.new,
);

class PanelOpen extends Notifier<bool> {
  PanelOpen(this.host);

  /// The panel this flag belongs to — the family argument.
  final PanelHost host;

  @override
  bool build() => false;

  void toggle() => state = !state;

  /// Shows the panel without closing it when it is already up — what opening a
  /// tab in it means, as opposed to pressing its button.
  void open() => state = true;

  void close() => state = false;
}

/// The tabs of one panel. Per host, because the panels are separate places to
/// work: opening a terminal beside the conversation must not change what is
/// open under it, or beside a project.
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
  /// test can assert against. Prefixed by the panel so the counters can't
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
    ref.read(panelOpenProvider(host).notifier).open();
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
      ref.read(panelOpenProvider(host).notifier).open();
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
    // closes a tab on their way out of the screen it was on.
    //
    // A shell has to be killed. Files only has state — but that state is keyed
    // by this id and nothing else will ever ask for it again, so left alone it
    // is a set of open folder paths per Files tab the session ever had.
    //
    // Naming three features from `shared/` is the exemption `panel_feature_view`
    // and `shared/layouts/widgets/section_view.dart` already take: a table that
    // maps panels onto features has to name both sides. Keeping it to this one
    // method is what stops it spreading.
    ref.read(terminalSessionsProvider.notifier).endSession(id);
    ref.invalidate(filesBrowserProvider(id));
    // A terminal put on the message being typed, whose tab is now gone. The chip
    // would still be there promising a screen that no longer exists, and Send
    // would quietly carry nothing.
    ref.read(attachedTerminalsProvider.notifier).remove(id);

    final rest = [...state.tabs]..removeAt(index);
    if (rest.isEmpty) {
      state = PanelTabsState();
      ref.read(panelOpenProvider(host).notifier).close();
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
