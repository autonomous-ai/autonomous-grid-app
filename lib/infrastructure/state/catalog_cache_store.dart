import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// One saved catalog answer: the response body exactly as the API sent it, and
/// when it arrived.
class CatalogCacheEntry {
  const CatalogCacheEntry({required this.body, required this.savedAt});

  /// The raw JSON the catalog returned. Kept verbatim so a saved copy is read
  /// back through the very same parser a live call uses — a re-encoded copy of
  /// our own parsed objects would quietly drop every field the app doesn't read
  /// yet, and drift from the API on the next server change.
  final String body;

  /// When this body came off the wire — what the UI turns into "saved 2 hours
  /// ago", so nobody mistakes the fallback for live data.
  final DateTime savedAt;
}

/// The last good response for each catalog request, so the model manager still
/// lists models — and still starts downloads — while the catalog is unreachable.
///
/// Persisted as `~/.grid/app/catalog_cache.json`. App-owned and lenient like the
/// other app stores: a missing or corrupt file reads as "nothing saved yet", and
/// a write that fails costs a later cache miss, never the call in flight. The
/// file is overridable so tests point at a temp path and never touch a real grid
/// home.
class CatalogCacheStore {
  CatalogCacheStore({File? file}) : _file = file ?? GridPaths.catalogCacheFile;

  final File _file;

  /// How many responses are kept. The catalog is asked something different for
  /// every search term, ranking and model opened, so without a cap the file
  /// would grow with each one; the oldest go first. Bodies run to tens of
  /// kilobytes and the whole file is rewritten per save, which is the other
  /// reason this number stays small.
  static const int maxEntries = 16;

  /// What was saved for [key], or null when nothing was (or the file is
  /// unreadable).
  CatalogCacheEntry? read(String key) => _load()[key];

  /// Remember [body] as the answer to [key], replacing any older copy.
  void save(String key, String body) {
    if (body.isEmpty) return;
    final entries = _load()
      ..[key] = CatalogCacheEntry(body: body, savedAt: DateTime.now());
    _write(_capped(entries));
  }

  /// The newest [maxEntries], oldest dropped.
  static Map<String, CatalogCacheEntry> _capped(
    Map<String, CatalogCacheEntry> entries,
  ) {
    if (entries.length <= maxEntries) return entries;
    final ordered = entries.entries.toList()
      ..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
    return {
      for (final entry in ordered.take(maxEntries)) entry.key: entry.value,
    };
  }

  Map<String, CatalogCacheEntry> _load() {
    try {
      if (!_file.existsSync()) return {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return {};
      final out = <String, CatalogCacheEntry>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final body = value['body'];
        final savedAt = DateTime.tryParse('${value['saved_at']}');
        if (body is! String || body.isEmpty || savedAt == null) continue;
        out['${entry.key}'] = CatalogCacheEntry(body: body, savedAt: savedAt);
      }
      return out;
    } on Object {
      return {};
    }
  }

  void _write(Map<String, CatalogCacheEntry> entries) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        jsonEncode({
          for (final entry in entries.entries)
            entry.key: {
              'saved_at': entry.value.savedAt.toIso8601String(),
              'body': entry.value.body,
            },
        }),
        flush: true,
      );
    } on Object {
      // A cache that can't be written is a miss next time, never a failure now.
    }
  }
}

/// Key for the device-fit suggestion on [apiUrl].
///
/// One key per control plane and no more: this machine has one hardware profile,
/// so the request that produced the saved copy is the request that would be made
/// again. New hardware makes the saved ranking stale rather than wrong — and it
/// is only ever read when the live call already failed.
String catalogSuggestKey(String apiUrl) => 'suggest|$apiUrl';

/// Key for one page of the browsable list — a ranking and a search term make
/// two different answers, so they make two different keys.
String catalogListKey({
  required String apiUrl,
  required String sort,
  required String query,
}) => 'list|$apiUrl|$sort|$query';

/// Key for one model's version list.
String catalogDetailKey({required String apiUrl, required String repoId}) =>
    'detail|$apiUrl|$repoId';

/// The catalog fallback store, overridden in tests with a temp-file-backed one.
final catalogCacheStoreProvider = Provider<CatalogCacheStore>(
  (ref) => CatalogCacheStore(),
);
