import 'dart:io';

/// A GGUF model file found under `~/.grid/models/`. Discovered by scanning the
/// directory — never by parsing `grid models list`. Mirrors the CLI
/// `StoredModel` (store.py:12). See CLI_Integration_Contract §1.3.
class LocalModel {
  const LocalModel({
    required this.name,
    required this.path,
    required this.sizeBytes,
  });

  final String name;
  final String path;
  final int sizeBytes;

  double get sizeGb => sizeBytes / 1e9;
}

/// A model still coming down: the CLI streams a download into `<file>.gguf.part`
/// and only renames it to `.gguf` once every byte has landed (download.py). So a
/// `.part` on disk means a download is in progress — or was interrupted and can
/// resume — which is a different thing from "no model here, start a fresh one".
///
/// The app watches for these so a half-downloaded model doesn't read as an empty
/// computer (which would prompt a redundant pull), and so nothing kicks off a
/// second `grid pull` writing the very same part-file. It mirrors the CLI's own
/// store, which likewise skips `.part`/`.tmp` when it lists finished models.
class DownloadingModel {
  const DownloadingModel({
    required this.name,
    required this.path,
    required this.bytesSoFar,
  });

  /// The model's eventual filename — the `.part` suffix stripped, so it lines up
  /// with the [LocalModel.name] it becomes once complete.
  final String name;
  final String path;

  /// How much has landed so far. There's no honest percentage without the total
  /// size (which the part-file alone doesn't carry), so callers show the amount,
  /// not a bar.
  final int bytesSoFar;

  double get gbSoFar => bytesSoFar / 1e9;

  /// What the file is called on disk right now — [name] with the `.part`
  /// back on. This is the name `grid rm` takes to delete a stalled
  /// download.
  String get fileName => '$name.part';
}

/// The in-progress downloads in [modelsDir]: every `*.part` the CLI hasn't
/// finished and renamed to `.gguf` yet. Pure and directory-injectable so it's
/// unit-tested against a temp dir, and lenient — a missing directory is simply
/// no downloads, never a throw.
List<DownloadingModel> scanDownloadingModels(Directory modelsDir) {
  if (!modelsDir.existsSync()) return const [];
  const suffix = '.part';
  final out = <DownloadingModel>[];
  for (final entity in modelsDir.listSync()) {
    if (entity is! File || !entity.path.endsWith(suffix)) continue;
    final filename = entity.uri.pathSegments.last;
    out.add(
      DownloadingModel(
        name: filename.substring(0, filename.length - suffix.length),
        path: entity.path,
        bytesSoFar: entity.lengthSync(),
      ),
    );
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// A generated media file under `~/.grid/outputs/` (cli.py:946), shown in the
/// gallery.
class MediaOutput {
  const MediaOutput({required this.path, required this.filename});

  final String path;
  final String filename;

  bool get isVideo => filename.endsWith('.mp4') || filename.endsWith('.webm');
}
