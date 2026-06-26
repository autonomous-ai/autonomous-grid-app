import '../../../infrastructure/cli/grid_cli_service.dart';

/// One entry from `grid models list --catalog`'s "Recommended catalog:" section.
/// The CLI already filters this list to the host's target (Apple Silicon /
/// NVIDIA), so its first language entry is the right default for this machine.
class CatalogModel {
  const CatalogModel({
    required this.label,
    required this.repoFile,
    required this.kind,
  });

  /// Catalog label — passed verbatim to `grid models pull <label>`.
  final String label;

  /// `hf_repo/quantized_file`, shown for context.
  final String repoFile;

  /// "language" | "embedding".
  final String kind;

  bool get isLanguage => kind == 'language';
}

/// Reads the curated model catalog from the CLI (`grid models list --catalog`)
/// so the app never hardcodes model ids — the labels stay in sync with the CLI's
/// catalog.py. On any failure returns an empty list, and the setup flow then
/// simply skips the automatic model download.
class ModelCatalog {
  const ModelCatalog(this._service);

  final GridCliService? _service;

  Future<List<CatalogModel>> recommended() async {
    final service = _service;
    if (service == null) return const [];
    final result = await service.run(const ['models', 'list', '--catalog']);
    if (!result.ok) return const [];
    return parse(result.stdout);
  }

  /// The default language model to serve, or null when the catalog has none for
  /// this machine.
  Future<CatalogModel?> defaultLanguageModel() async {
    final entries = await recommended();
    for (final e in entries) {
      if (e.isLanguage) return e;
    }
    return entries.isEmpty ? null : entries.first;
  }

  /// Parses the "Recommended catalog:" block. Exposed for tests.
  static List<CatalogModel> parse(String stdout) {
    final lines = stdout.split('\n');
    final start = lines.indexWhere((l) => l.trim() == 'Recommended catalog:');
    if (start < 0) return const [];

    final models = <CatalogModel>[];
    for (final raw in lines.skip(start + 1)) {
      if (raw.trim().isEmpty) continue;
      final entry = _parseEntry(raw);
      if (entry != null) models.add(entry);
    }
    return models;
  }

  // `  qwen36-35b-a3b-mtp   unsloth/Repo/file.gguf (Apple Silicon, min 32 GB, language)`
  static final _kindPattern = RegExp(r',\s*(\w+)\)\s*$');

  static CatalogModel? _parseEntry(String line) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 2) return null;
    return CatalogModel(
      label: tokens[0],
      repoFile: tokens[1],
      kind: _kindPattern.firstMatch(line)?.group(1) ?? 'language',
    );
  }
}
