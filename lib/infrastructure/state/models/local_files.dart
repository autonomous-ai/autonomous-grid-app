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

/// A generated media file under `~/.grid/outputs/` (cli.py:946), shown in the
/// gallery.
class MediaOutput {
  const MediaOutput({required this.path, required this.filename});

  final String path;
  final String filename;

  bool get isVideo =>
      filename.endsWith('.mp4') || filename.endsWith('.webm');
}
