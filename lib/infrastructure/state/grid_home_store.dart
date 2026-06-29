import 'dart:convert';
import 'dart:io';

import 'package:toml/toml.dart';

import '../../core/grid_paths.dart';
import 'models/credentials_file.dart';
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

  NetworkConfig? readNetworkConfig(String networkId) {
    final map = _readToml(GridPaths.networkConfigFile(networkId));
    return map == null ? null : NetworkConfig.fromToml(map);
  }

  /// The active cloud grid (name or network_id) the user picked with
  /// `grid use`, read from `~/.grid/state.json` (`active.cloud`). Null when the
  /// file is missing/unreadable or nothing is selected — callers fall back to a
  /// default grid. Lenient like the CLI: a corrupt state file must never brick
  /// the app. See [GridPaths.stateFile].
  String? readActiveCloudGrid() {
    final file = GridPaths.stateFile;
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final active = decoded['active'];
      if (active is! Map) return null;
      final cloud = active['cloud'];
      return cloud is String && cloud.isNotEmpty ? cloud : null;
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

  Map<String, dynamic>? _readToml(File file) {
    if (!file.existsSync()) return null;
    try {
      return TomlDocument.parse(file.readAsStringSync()).toMap();
    } on Exception {
      return null;
    }
  }
}
