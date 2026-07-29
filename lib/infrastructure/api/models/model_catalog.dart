import 'dart:convert';

import 'model_icon_service.dart';

/// One downloadable model the catalog returns — the shape shared by the
/// suggest response's `pick` and each `alternatives[]` entry (the Model Catalog
/// API, `POST /v1/grid/catalog`). Everything needed to show a card and start a
/// download is here; the server has already ranked and chosen the quant.
///
/// The "no model fits" sentinel (`{repo_id: null, …}`) parses to an entry whose
/// [hasModel] is false — callers show an empty state instead of a card.
class CatalogModelPick {
  const CatalogModelPick({
    required this.repoId,
    required this.version,
    required this.sizeBytes,
    required this.file,
    required this.maxCtx,
    required this.estTokPerSec,
    required this.createdAt,
    required this.downloads,
    required this.likes,
    required this.paramsB,
    required this.arch,
    required this.format,
    required this.pullSpec,
    required this.urls,
  });

  /// Model name, e.g. `Qwen/Qwen2.5-3B-Instruct-GGUF`. Null in the "no match"
  /// sentinel.
  final String? repoId;

  /// The quant the server picked for this device, e.g. `Q5_K_M`.
  final String? version;

  /// Download size in bytes (server field `size` / `size_bytes`).
  final int sizeBytes;

  /// The GGUF filename, e.g. `qwen2.5-3b-instruct-q5_k_m.gguf`. Used to tell a
  /// suggestion already on disk apart from one still to download.
  final String? file;

  /// Maximum context length in tokens.
  final int maxCtx;

  /// Estimated generation speed on this device, tokens/sec. 0 when unknown (the
  /// list mode has no device, so it never sets this).
  final double estTokPerSec;

  /// ISO 8601 timestamp of when the model was first indexed by the catalog.
  /// Null when the server didn't include it (suggest picks pre-fix).
  final DateTime? createdAt;

  /// Total HuggingFace downloads. 0 when the server didn't include it.
  final int downloads;

  /// Total HuggingFace likes. 0 when the server didn't include it.
  final int likes;

  /// Parameter count in billions (e.g. 7.0 for a 7B model). Null when unknown.
  final double? paramsB;

  /// Parsed GGUF arch metadata (architecture, block_count, head_count, …).
  /// Null when the record didn't carry an arch dict.
  final Map<String, dynamic>? arch;

  /// File format label surfaced for the sidebar badge (`"GGUF"`,
  /// `"safetensors"`, …). Null when the server couldn't detect it.
  final String? format;

  /// The `<repo>:<file>` spec handed to `grid pull` to download this model.
  final String? pullSpec;

  /// Direct download link(s) — more than one for a split GGUF.
  final List<String> urls;

  /// Whether this entry names a real, downloadable model (vs the "no match"
  /// sentinel or a malformed row).
  bool get hasModel =>
      repoId != null &&
      repoId!.isNotEmpty &&
      pullSpec != null &&
      pullSpec!.isNotEmpty;

  /// Short architecture label for the sidebar badge — e.g. `qwen2`, `llama`,
  /// `mistral`. Falls back to the repo-id tail when the arch dict is missing.
  String get archLabel {
    final a = arch;
    if (a != null) {
      final v = a['architecture'];
      if (v is String && v.isNotEmpty) return v;
    }
    if (repoId == null || repoId!.isEmpty) return '';
    final tail = repoId!.contains('/') ? repoId!.split('/').last : repoId!;
    final stripped = tail.replaceAll(
      RegExp(r'[-_]GGUF$', caseSensitive: false),
      '',
    );
    final parts = stripped
        .split(RegExp(r'[-_]'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final first = parts.first.toLowerCase();
    return RegExp(r'^[a-z]+\d').firstMatch(first)?.group(0) ?? first;
  }

  /// LobeHub CDN URL for this model's provider icon, or null when unknown.
  String? get iconUrl => urlForModel(repoId ?? '');

  factory CatalogModelPick.fromJson(Map<String, dynamic> json) =>
      CatalogModelPick(
        repoId: json['repo_id'] as String?,
        version: json['version'] as String?,
        // Suggest speaks `size`; list's versions speak `size_bytes`.
        sizeBytes:
            (json['size'] as num?)?.toInt() ??
            (json['size_bytes'] as num?)?.toInt() ??
            0,
        file: json['file'] as String?,
        maxCtx:
            (json['max_ctx'] as num?)?.toInt() ??
            (json['max_context'] as num?)?.toInt() ??
            0,
        estTokPerSec: (json['est_tok_s'] as num?)?.toDouble() ?? 0,
        createdAt: _parseDate(json['created_at']),
        downloads: (json['downloads'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        paramsB: (json['params_b'] as num?)?.toDouble(),
        arch: (json['arch'] as Map?)?.cast<String, dynamic>(),
        format: json['format'] as String?,
        pullSpec: json['pull_spec'] as String?,
        urls: _stringList(json['urls']),
      );
}

/// The suggest-mode response (`{device}` in the request body): ranked models
/// best-first. [models] is the full ordered list; [pick] is just `models.first`
/// for callers that only want the top recommendation.
class CatalogSuggestion {
  const CatalogSuggestion({required this.models});

  final List<CatalogModelPick> models;

  /// Best-ranked model, or null when nothing fits this device.
  CatalogModelPick? get pick => models.isEmpty ? null : models.first;

  factory CatalogSuggestion.fromJson(Map<String, dynamic> json) =>
      CatalogSuggestion(
        models: [
          for (final m in (json['models'] as List?) ?? const [])
            if (m is Map) CatalogModelPick.fromJson(m.cast<String, dynamic>()),
        ],
      );
}

List<String> _stringList(Object? raw) => [
  for (final item in (raw as List?) ?? const [])
    if (item is String && item.isNotEmpty) item,
];

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// One entry from `POST /v1/grid/catalog` list mode — a single repo with display
/// facts but no per-version detail (use [ModelDetail] for that).
class CatalogListEntry {
  const CatalogListEntry({
    required this.repoId,
    required this.downloads,
    required this.likes,
    required this.trendingScore,
    required this.createdAt,
    required this.paramsB,
    this.format,
    this.architecture,
  });

  final String repoId;
  final int downloads;
  final int likes;
  final double trendingScore;
  final DateTime? createdAt;
  final double? paramsB;

  /// File format label surfaced for the sidebar badge (`"GGUF"`, `"safetensors"`, …).
  final String? format;

  /// Parsed GGUF arch metadata (architecture, block_count, head_count, …).
  final Map<String, dynamic>? architecture;

  /// Short architecture label for the sidebar badge — e.g. `qwen2`, `llama`,
  /// `mistral`. Falls back to the repo-id tail when the arch dict is missing.
  String get archLabel {
    final a = architecture;
    if (a != null) {
      final v = a['architecture'];
      if (v is String && v.isNotEmpty) return v;
    }
    if (repoId.isEmpty) return '';
    final tail = repoId.contains('/') ? repoId.split('/').last : repoId;
    final stripped = tail.replaceAll(
      RegExp(r'[-_]GGUF$', caseSensitive: false),
      '',
    );
    final parts = stripped
        .split(RegExp(r'[-_]'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final first = parts.first.toLowerCase();
    return RegExp(r'^[a-z]+\d').firstMatch(first)?.group(0) ?? first;
  }

  /// LobeHub CDN URL for this model's provider icon, or null when unknown.
  String? get iconUrl => urlForModel(repoId);

  factory CatalogListEntry.fromJson(Map<String, dynamic> json) =>
      CatalogListEntry(
        repoId: json['repo_id'] as String? ?? '',
        downloads: (json['downloads'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        trendingScore: (json['trending_score'] as num?)?.toDouble() ?? 0,
        createdAt: _parseDate(json['created_at']),
        paramsB: (json['params_b'] as num?)?.toDouble(),
        format: json['format'] as String?,
        architecture: (json['arch'] as Map?)?.cast<String, dynamic>(),
      );
}

/// Parses the list-mode body into a flat list of entries.
List<CatalogListEntry>? parseCatalogList(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final models = decoded['models'];
    if (models is! List) return null;
    return [
      for (final m in models)
        if (m is Map) CatalogListEntry.fromJson(m.cast<String, dynamic>()),
    ];
  } on FormatException {
    return null;
  }
}

/// Parses the raw catalog response body into a [CatalogSuggestion], or null when
/// the body isn't the suggest shape (wrong mode, malformed JSON). Kept beside the
/// models so the client and its tests decode one way.
CatalogSuggestion? parseSuggestResponse(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    if (decoded['mode'] != null && decoded['mode'] != 'suggest') return null;
    return CatalogSuggestion.fromJson(decoded.cast<String, dynamic>());
  } on FormatException {
    return null;
  }
}
