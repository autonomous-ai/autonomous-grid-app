import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../../features/files/logic/files_browser.dart';
import 'panel_tabs.dart';

/// One tab as it is remembered: enough to open it again where it was.
///
/// Only what can honestly come back. A browser tab keeps its address and not
/// its history — the engine holding that is gone with the window. A Files tab
/// keeps the folders it had open and the file it was showing. A terminal keeps
/// only the fact that it was there: its shell ended with the app, and what
/// comes back is a new one in the same folder.
@immutable
class PanelTabMemory {
  const PanelTabMemory({
    required this.feature,
    required this.title,
    this.url = '',
    this.files,
  });

  final PanelFeature feature;

  /// The tab's name when it was put away, so "Files 2" keeps its number and a
  /// browser tab shows its page's name until the page says it again.
  final String title;

  /// A browser tab's address. Empty for every other feature, and for a browser
  /// tab that was never pointed anywhere.
  final String url;

  /// A Files tab's place in its folder. Null for every other feature.
  final FilesBrowserState? files;

  Map<String, Object?> toJson() => {
    'feature': feature.name,
    'title': title,
    if (url.isNotEmpty) 'url': url,
    if (files case final place?) 'files': place.toJson(),
  };

  /// Null for anything this build can't open — a feature a later version
  /// added, or an entry somebody edited by hand.
  static PanelTabMemory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final feature = PanelFeature.values.asNameMap()[raw['feature']];
    if (feature == null) return null;
    final title = raw['title'];
    final url = raw['url'];
    return PanelTabMemory(
      feature: feature,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : feature.label,
      url: feature == PanelFeature.browser && url is String ? url.trim() : '',
      files: feature == PanelFeature.files
          ? FilesBrowserState.fromJson(raw['files'])
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelTabMemory &&
      other.feature == feature &&
      other.title == title &&
      other.url == url &&
      other.files == files;

  @override
  int get hashCode => Object.hash(feature, title, url, files);
}

/// What one side panel was showing for one project: whether it was open, the
/// tabs in it, and which of them was in front.
@immutable
class PanelScopeMemory {
  PanelScopeMemory({
    this.open = false,
    List<PanelTabMemory> tabs = const [],
    this.active,
  }) : tabs = List.unmodifiable(tabs);

  /// A project the panel was never opened beside.
  static final empty = PanelScopeMemory();

  final bool open;
  final List<PanelTabMemory> tabs;

  /// Which of [tabs] was in front, by position. A tab's id belongs to one
  /// launch, so its position is the only name for it that survives the next.
  final int? active;

  /// Nothing worth a line in the file: a panel shut with nothing in it is what
  /// every project starts as anyway.
  bool get isEmpty => !open && tabs.isEmpty;

  Map<String, Object?> toJson() => {
    'open': open,
    if (active != null) 'active': active,
    'tabs': [for (final tab in tabs) tab.toJson()],
  };

  /// Lenient, like the app's other stores: a tab this build can't open is
  /// dropped, and the tab that was in front stays in front — its position is
  /// counted among the tabs that are kept, not among the ones written.
  static PanelScopeMemory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final written = raw['tabs'];
    final tabs = <PanelTabMemory>[];
    int? active;
    if (written is List) {
      for (final (i, entry) in written.indexed) {
        final tab = PanelTabMemory.fromJson(entry);
        if (tab == null) continue;
        if (i == raw['active']) active = tabs.length;
        tabs.add(tab);
      }
    }
    return PanelScopeMemory(
      open: raw['open'] == true,
      tabs: tabs,
      active: active,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelScopeMemory &&
      other.open == open &&
      other.active == active &&
      listEquals(other.tabs, tabs);

  @override
  int get hashCode => Object.hash(open, active, Object.hashAll(tabs));
}

/// Persists what each side panel had open, per project — one file per panel,
/// `~/.grid/app/panel_tabs/<panel>.json`, keyed by the scope the panel was
/// showing (see `panelScopeProvider`).
///
/// App-owned and lenient like the other app stores: a missing or corrupt file
/// reads as nothing remembered — every project's panel starts shut, which is
/// what it did before there was a file at all — rather than throwing.
class PanelMemoryStore {
  PanelMemoryStore({Directory? dir}) : _dir = dir ?? GridPaths.panelTabsDir;

  final Directory _dir;

  File _file(PanelHost host) => File('${_dir.path}/${host.name}.json');

  Map<String, PanelScopeMemory> load(PanelHost host) {
    try {
      final file = _file(host);
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          '${entry.key}': ?PanelScopeMemory.fromJson(entry.value),
      };
    } on Object {
      return {};
    }
  }

  /// Write [scopes] out, leaving out the ones with nothing to remember so a
  /// project visited once doesn't keep a line in the file for ever.
  void save(PanelHost host, Map<String, PanelScopeMemory> scopes) {
    final file = _file(host);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in scopes.entries)
          if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
      }),
      flush: true,
    );
  }
}

/// The panel store, overridden in tests with a temp-dir-backed one.
final panelMemoryStoreProvider = Provider<PanelMemoryStore>(
  (ref) => PanelMemoryStore(),
);
