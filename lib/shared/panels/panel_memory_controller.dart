import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/browser/logic/browser_tab_controller.dart';
import '../../features/files/logic/files_browser.dart';
import '../../infrastructure/logging/app_log.dart';
import 'panel_memory.dart';
import 'panel_scope.dart';
import 'panel_tabs.dart';

/// What each project's side panel had open, kept for it — through a trip to
/// another project and back, and through the app closing.
///
/// Until 2026-09-10 a panel was one set of tabs for the whole app: a page
/// opened beside one project's chat was still there beside the next project's,
/// and none of it was there after a restart. Now a project is a place the
/// panel belongs to, the way a folder is the place an editor window belongs to.
///
/// Two layers, because they can hold different things:
///
///  - **Within a launch**, the tabs of a project you leave are *parked*, not
///    closed. A build running in one of its terminals keeps running and is
///    still there when you come back. Only a browser tab's page starts over —
///    its engine went with the widget — and it opens on the address it was on.
///  - **Across launches**, what comes back is what a file can hold: which
///    tabs, in what order, which was in front, whether the panel was open, a
///    page's address and a Files tab's place. A terminal comes back as a new
///    shell in the same folder; the one it held ended with the app.
///
/// Written through on every change, like the app's other stores, so a crash or
/// a `kill -9` loses nothing that was on screen a moment before. The state is
/// the scope the panel is showing ([panelScopeProvider]), null until one is
/// known.
///
/// **Listen to it; reading it is not enough.** Riverpod 3 pauses a provider no
/// one listens to, and the listeners it holds with it — so a memory that was
/// only read would take up the first project and never hear the next. The
/// shell holds it open (`HomeShell`).
final panelMemoryProvider =
    NotifierProvider.family<PanelMemory, String?, PanelHost>(PanelMemory.new);

class PanelMemory extends Notifier<String?> {
  PanelMemory(this.host);

  /// The panel this remembers — the family argument.
  final PanelHost host;

  /// Every scope's memory as the file holds it, kept current so that a write
  /// is this map written out rather than a read of the file and then a write.
  Map<String, PanelScopeMemory> _saved = {};

  /// The live tabs of each scope left this launch.
  ///
  /// Held until the user comes back or the app quits — including for a project
  /// removed in the meantime, whose parked terminals then run unseen until the
  /// app closes. Accepted: telling those apart would mean teaching this which
  /// scopes still exist, for a shell that ends with the app anyway.
  final Map<String, ({PanelTabsState tabs, bool open})> _parked = {};

  /// A subscription for each tab on screen whose contents are remembered, so a
  /// page moving on or a file being picked is written down as it happens.
  final Map<String, ProviderSubscription<Object?>> _contents = {};

  /// Set while a switch puts one scope's tabs away and brings another's out.
  /// Every step of that fires the listeners below, and the half-switched panel
  /// in between belongs to neither scope.
  bool _switching = false;

  @override
  String? build() {
    _saved = ref.read(panelMemoryStoreProvider).load(host);
    ref.listen(panelScopeProvider(host), (_, scope) => enter(scope));
    ref.listen(panelTabsProvider(host), (_, tabs) {
      _followContents(tabs);
      _remember();
    });
    ref.listen(panelOpenProvider(host), (_, _) => _remember());
    return null;
  }

  /// Take up the scope already on screen.
  ///
  /// The listener above only hears a *change*, and by the time the shell calls
  /// this the chat the app reopened on may already be chosen. Called outside
  /// any build, because taking a scope up opens its tabs.
  void start() => enter(ref.read(panelScopeProvider(host)));

  /// Show [scope]'s tabs in the panel, parking the ones there now.
  ///
  /// Null is "not known yet" and changes nothing: the tabs on screen stay
  /// where they are until there is somewhere better to put them.
  void enter(String? scope) {
    final left = state;
    if (scope == null || scope == left) return;
    // Tabs opened before the launch knew whose panel this was — in the moment
    // the history takes to read — become this scope's rather than being
    // replaced by what it had last time: the user opened them just now.
    final adopt =
        left == null && ref.read(panelTabsProvider(host)).tabs.isNotEmpty;
    _switching = true;
    try {
      if (left != null) _park(left);
      state = scope;
      if (!adopt) _bringOut(scope);
    } finally {
      _switching = false;
    }
    _remember();
  }

  void _park(String scope) => _parked[scope] = (
    tabs: ref.read(panelTabsProvider(host)),
    open: ref.read(panelOpenProvider(host)),
  );

  /// [scope]'s tabs as it left them: alive if it was parked this launch, from
  /// the file if it wasn't, and none at all for a scope never opened.
  void _bringOut(String scope) {
    final parked = _parked.remove(scope);
    if (parked != null) {
      _show(parked.tabs, open: parked.open);
      return;
    }
    _restore(_saved[scope] ?? PanelScopeMemory.empty);
  }

  void _show(PanelTabsState tabs, {required bool open}) {
    ref.read(panelTabsProvider(host).notifier).swap(tabs);
    final panel = ref.read(panelOpenProvider(host).notifier);
    if (open) {
      panel.open();
    } else {
      panel.close();
    }
  }

  /// Open [memory]'s tabs again and tell each where it was.
  void _restore(PanelScopeMemory memory) {
    final (:tabs, :activeId) = _revive(memory);
    _show(
      PanelTabsState(
        tabs: [for (final (tab, _) in tabs) tab],
        activeId: activeId ?? tabs.firstOrNull?.$1.id,
      ),
      open: memory.open,
    );
    for (final (tab, saved) in tabs) {
      _refill(tab.id, saved);
    }
  }

  /// [memory]'s tabs under ids of this launch — an id belongs to one — and
  /// which of them goes in front.
  ({List<(PanelTab, PanelTabMemory)> tabs, String? activeId}) _revive(
    PanelScopeMemory memory,
  ) {
    final ids = ref.read(panelTabsProvider(host).notifier);
    final tabs = <(PanelTab, PanelTabMemory)>[];
    String? activeId;
    for (final (i, saved) in memory.tabs.indexed) {
      // A tab this computer can't draw — a browser remembered on a Mac and
      // read on Linux — is left out, the way the launcher leaves its row out.
      if (!availablePanelFeatures.contains(saved.feature)) continue;
      final tab = PanelTab(
        id: ids.nextId(),
        feature: saved.feature,
        title: saved.title,
      );
      if (i == memory.active) activeId = tab.id;
      tabs.add((tab, saved));
    }
    return (tabs: tabs, activeId: activeId);
  }

  /// Hand back what [saved]'s own feature kept. Only two features keep
  /// anything: a browser its address, Files its place.
  void _refill(String tabId, PanelTabMemory saved) {
    if (saved.feature == PanelFeature.browser) {
      ref.read(browserTabProvider(tabId).notifier).restore(saved.url);
    }
    if (saved.files case final place?) {
      ref.read(filesBrowserProvider(tabId).notifier).restore(place);
    }
  }

  /// Write the scope on screen down, if it has changed since it last was.
  void _remember() {
    final scope = state;
    if (_switching || scope == null) return;
    final now = _snapshot();
    if (now == (_saved[scope] ?? PanelScopeMemory.empty)) return;
    _saved[scope] = now;
    try {
      ref.read(panelMemoryStoreProvider).save(host, _saved);
    } on FileSystemException catch (error, stack) {
      // Nothing on screen depends on the file — the panel is right as it is,
      // only the next launch would be wrong — so a disk that refused the write
      // is a line in the log rather than something put in front of the user.
      ref
          .read(appLogProvider)
          .failure(
            'side-panel',
            'Could not remember what the side panel had open',
            error: error,
            stackTrace: stack,
          );
    }
  }

  PanelScopeMemory _snapshot() {
    final tabs = ref.read(panelTabsProvider(host));
    final active = tabs.tabs.indexWhere((tab) => tab.id == tabs.activeId);
    return PanelScopeMemory(
      open: ref.read(panelOpenProvider(host)),
      tabs: [for (final tab in tabs.tabs) _tabMemory(tab)],
      active: active < 0 ? null : active,
    );
  }

  PanelTabMemory _tabMemory(PanelTab tab) => PanelTabMemory(
    feature: tab.feature,
    title: tab.title,
    url: tab.feature == PanelFeature.browser
        ? ref.read(browserTabProvider(tab.id)).url
        : '',
    files: tab.feature == PanelFeature.files
        ? ref.read(filesBrowserProvider(tab.id)).remembered
        : null,
  );

  /// One subscription per remembered tab on screen: a tab that arrives gets
  /// one, and a tab that has gone — closed, or parked with its project — loses
  /// its own.
  void _followContents(PanelTabsState tabs) {
    final ids = {for (final tab in tabs.tabs) tab.id};
    for (final id in [..._contents.keys]) {
      if (!ids.contains(id)) _contents.remove(id)?.close();
    }
    for (final tab in tabs.tabs) {
      if (_contents.containsKey(tab.id)) continue;
      final subscription = _follow(tab);
      if (subscription != null) _contents[tab.id] = subscription;
    }
  }

  ProviderSubscription<Object?>? _follow(PanelTab tab) => switch (tab.feature) {
    PanelFeature.browser => ref.listen(
      browserTabProvider(tab.id).select((page) => page.url),
      (_, _) => _remember(),
    ),
    PanelFeature.files => ref.listen(
      filesBrowserProvider(tab.id).select((files) => files.remembered),
      (_, _) => _remember(),
    ),
    PanelFeature.review || PanelFeature.terminal => null,
  };
}
