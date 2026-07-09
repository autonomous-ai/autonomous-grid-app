import 'dart:convert';
import 'dart:io';

import 'package:toml/toml.dart';

import '../../core/grid_paths.dart';
import 'models/credentials_file.dart';
import 'models/engine_run.dart';
import 'models/local_files.dart';
import 'models/network_config.dart';

/// Reads state straight off `~/.grid` (nguồn 1 in the contract). This is the
/// robust path — it reads exactly what the CLI writes, so it never breaks on a
/// reworded log line. Mutations still go through the CLI; this only reads.
class GridHomeStore {
  const GridHomeStore();

  CredentialsFile readCredentials() {
    final map = _readToml(GridPaths.credentialsFile);
    return map == null ? CredentialsFile.empty : CredentialsFile.fromToml(map);
  }

  /// Sign-out: remove the local credentials file. The one mutation this store
  /// performs — there is no documented `grid auth logout`, and `~/.grid` is the
  /// app's source of truth, so deleting the file logs the user out.
  void clearCredentials() {
    final file = GridPaths.credentialsFile;
    if (file.existsSync()) file.deleteSync();
  }

  /// Service kinds that already have a stored API-engine key in
  /// `~/.grid/api_keys.toml` (a `[<kind>]` table with a non-empty `key`). Lets
  /// the hosted-provider block skip re-asking for a key the CLI already saved on
  /// a prior successful join. Reads presence only — never the key itself.
  /// Lenient: a missing/corrupt file yields an empty set, never throws.
  Set<String> storedApiKinds() {
    final map = _readToml(GridPaths.apiKeysFile);
    if (map == null) return const {};
    final kinds = <String>{};
    map.forEach((kind, entry) {
      final key = entry is Map ? entry['key'] : null;
      if (key is String && key.isNotEmpty) kinds.add(kind);
    });
    return kinds;
  }

  NetworkConfig? readNetworkConfig(String networkId) {
    final map = _readToml(GridPaths.networkConfigFile(networkId));
    return map == null ? null : NetworkConfig.fromToml(map);
  }

  /// The active remote grid (name or network_id) the user picked with
  /// `grid use`, read from `~/.grid/state.json` (`active.remote`). Null when the
  /// file is missing/unreadable or nothing is selected — callers fall back to a
  /// default grid. Lenient like the CLI: a corrupt state file must never brick
  /// the app. See [GridPaths.stateFile].
  String? readActiveRemoteGrid() {
    final file = GridPaths.stateFile;
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final active = decoded['active'];
      if (active is! Map) return null;
      final remote = active['remote'];
      return remote is String && remote.isNotEmpty ? remote : null;
    } on Exception {
      return null;
    }
  }

  /// Scan `~/.grid/models/*.gguf` for local models.
  List<LocalModel> listLocalModels() {
    final dir = GridPaths.modelsDir;
    if (!dir.existsSync()) return const [];
    final out = <LocalModel>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.gguf')) continue;
      out.add(LocalModel(
        name: entity.uri.pathSegments.last,
        path: entity.path,
        sizeBytes: entity.lengthSync(),
      ));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Scan `~/.grid/outputs/*` for generated media.
  List<MediaOutput> listOutputs() {
    final dir = GridPaths.outputsDir;
    if (!dir.existsSync()) return const [];
    final out = <MediaOutput>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      out.add(MediaOutput(
        path: entity.path,
        filename: entity.uri.pathSegments.last,
      ));
    }
    out.sort((a, b) => b.filename.compareTo(a.filename));
    return out;
  }

  /// Every persisted run record under `~/.grid/run/engines/<grid_id>/` — one
  /// `<engine_id>.json` per detached engine `grid join` launched. We scan the
  /// directory rather than open `<name>.json` because the engine id is the CLI's
  /// own (`remote` in remote mode), NOT the app's `--name` (which it stores only
  /// as the display `meta_name`) — so guessing the filename by name misses the
  /// live record entirely. Lenient: a missing dir or an unreadable/foreign file
  /// is skipped, never thrown, so a bad record can't brick the provider UI.
  List<EngineRunRecord> listEngineRuns(String gridId) {
    final dir = GridPaths.engineRunDir(gridId);
    if (!dir.existsSync()) return const [];
    final out = <EngineRunRecord>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final record = _readEngineRunFile(entity);
      if (record != null) out.add(record);
    }
    return out;
  }

  EngineRunRecord? _readEngineRunFile(File file) {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return EngineRunRecord.fromJson(Map<String, dynamic>.from(decoded));
    } on Exception {
      return null;
    }
  }

  /// Grid ids that currently have at least one engine run record. Read before
  /// sign-out / app close so we can `grid leave` anything still serving — even an
  /// engine adopted from a prior session the app never reconciled this run.
  /// Lenient: a missing dir or an unreadable record is skipped, never thrown.
  List<String> listServingGrids() {
    final dir = GridPaths.runEnginesDir;
    if (!dir.existsSync()) return const [];
    final out = <String>[];
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final gridId = entity.path.split(Platform.pathSeparator).last;
      if (gridId.isEmpty) continue;
      if (listEngineRuns(gridId).isNotEmpty) out.add(gridId);
    }
    return out;
  }

  /// Tail of a resumed engine's log (`<engine_id>.log`), so the running card can
  /// show real context after a restart. Empty when missing/unreadable.
  List<String> readEngineRunLog(String gridId, String engineId,
      {int maxLines = 400}) {
    final file = GridPaths.engineRunLogFile(gridId, engineId);
    if (!file.existsSync()) return const [];
    try {
      final lines = file.readAsLinesSync();
      if (lines.length <= maxLines) return lines;
      return lines.sublist(lines.length - maxLines);
    } on Exception {
      return const [];
    }
  }

  Map<String, dynamic>? _readToml(File file) {
    if (!file.existsSync()) return null;
    try {
      return TomlDocument.parse(file.readAsStringSync()).toMap();
    } on Exception {
      return null;
    }
  }
}
