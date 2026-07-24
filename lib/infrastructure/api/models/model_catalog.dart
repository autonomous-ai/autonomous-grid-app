import 'dart:convert';

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

  factory CatalogModelPick.fromJson(Map<String, dynamic> json) =>
      CatalogModelPick(
        repoId: json['repo_id'] as String?,
        version: json['version'] as String?,
        // Suggest speaks `size`; list's versions speak `size_bytes`.
        sizeBytes: (json['size'] as num?)?.toInt() ??
            (json['size_bytes'] as num?)?.toInt() ??
            0,
        file: json['file'] as String?,
        maxCtx: (json['max_ctx'] as num?)?.toInt() ??
            (json['max_context'] as num?)?.toInt() ??
            0,
        estTokPerSec: (json['est_tok_s'] as num?)?.toDouble() ?? 0,
        pullSpec: json['pull_spec'] as String?,
        urls: _stringList(json['urls']),
      );
}

/// The suggest-mode response (`{device}` in the request body): the top [pick]
/// for this machine plus ranked [alternatives]. [ranked] flattens them into the
/// order to render — best first — dropping the "no match" sentinel.
class CatalogSuggestion {
  const CatalogSuggestion({required this.pick, required this.alternatives});

  final CatalogModelPick pick;
  final List<CatalogModelPick> alternatives;

  /// Every real model, best first: the pick then the alternatives (already
  /// ranked by the server). Empty when nothing fits this device.
  List<CatalogModelPick> get ranked => [
    if (pick.hasModel) pick,
    ...alternatives.where((m) => m.hasModel),
  ];

  factory CatalogSuggestion.fromJson(Map<String, dynamic> json) =>
      CatalogSuggestion(
        pick: CatalogModelPick.fromJson(
          (json['pick'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        alternatives: [
          for (final alt in (json['alternatives'] as List?) ?? const [])
            if (alt is Map)
              CatalogModelPick.fromJson(alt.cast<String, dynamic>()),
        ],
      );
}

List<String> _stringList(Object? raw) => [
  for (final item in (raw as List?) ?? const [])
    if (item is String && item.isNotEmpty) item,
];

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
