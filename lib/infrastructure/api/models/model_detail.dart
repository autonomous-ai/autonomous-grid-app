import 'dart:convert';

/// One downloadable version of a model, as returned by `GET /v1/grid/catalog/{repo_id}`.
/// Each entry has a [status] verdict when the request included `?device=`: the same
/// decode + prefill gates the suggest endpoint uses, so the detail panel's "can I
/// run this?" matches what the suggest list would have picked.
class ModelVersion {
  const ModelVersion({
    required this.version,
    required this.sizeBytes,
    required this.pullSpec,
    required this.urls,
    this.status,
    this.maxCtx,
  });

  /// Quant label, e.g. `Q5_K_M`. Null when the server didn't tag it.
  final String? version;

  /// Download size in bytes.
  final int sizeBytes;

  /// The `<repo>:<file>` spec handed to `grid pull` to download this version.
  final String? pullSpec;

  /// Direct download URL(s) — more than one for a split GGUF.
  final List<String> urls;

  /// Runnability verdict against the requested device. Null when no device was
  /// passed (the API can't tell without one).
  final VersionStatus? status;

  /// Maximum context length in tokens, if known for this version.
  final int? maxCtx;

  factory ModelVersion.fromJson(Map<String, dynamic> json) => ModelVersion(
    version: json['version'] as String?,
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    pullSpec: json['pull_spec'] as String?,
    urls: _stringList(json['urls']),
    status: VersionStatus.fromJson(json['status'] as String?),
    maxCtx:
        (json['max_ctx'] as num?)?.toInt() ??
        (json['max_context'] as num?)?.toInt(),
  );
}

/// Per-version runnability verdict (`runnable` | `partial` | `too_large`).
enum VersionStatus {
  runnable('runnable'),
  partial('partial'),
  tooLarge('too_large');

  const VersionStatus(this.wire);

  final String wire;

  static VersionStatus? fromJson(String? s) {
    if (s == null) return null;
    for (final v in VersionStatus.values) {
      if (v.wire == s) return v;
    }
    return null;
  }

  String get label => switch (this) {
    VersionStatus.runnable => 'Runs on this Mac',
    VersionStatus.partial => 'Partial — slow',
    VersionStatus.tooLarge => 'Too large for memory',
  };
}

/// Full model record from `GET /v1/grid/catalog/{repo_id}`. [versions] is empty
/// when the repo isn't in the catalog yet.
class ModelDetail {
  const ModelDetail({
    required this.repoId,
    required this.name,
    required this.versions,
    this.format,
    this.architecture,
    this.author,
    this.paramsB,
    this.likes = 0,
    this.downloads = 0,
    this.task,
  });

  final String repoId;
  final String? name;
  final List<ModelVersion> versions;

  /// File format label surfaced for the sidebar badge (`"GGUF"`, `"safetensors"`, …).
  final String? format;

  /// Short architecture label for the sidebar badge — e.g. `qwen2`, `llama`,
  /// `mistral`. Falls back to the repo-id tail when the arch dict is missing.
  final String? architecture;

  /// Author/organization that owns the model (e.g. `Qwen`, `meta-llama`).
  /// Derived from repo_id (first segment before `/`).
  final String? author;

  /// Parameter count in billions (e.g. 7.0 for a 7B model). Null when unknown.
  final double? paramsB;

  /// Total HuggingFace likes. 0 when the server didn't include it.
  final int likes;

  /// Total HuggingFace downloads. 0 when the server didn't include it.
  final int downloads;

  /// Task/pipeline tag (e.g. `text-generation`, `image-generation`).
  final String? task;

  factory ModelDetail.fromJson(Map<String, dynamic> json) => ModelDetail(
    repoId: json['repo_id'] as String? ?? '',
    name: json['name'] as String?,
    versions: [
      for (final v in (json['versions'] as List?) ?? const [])
        if (v is Map) ModelVersion.fromJson(v.cast<String, dynamic>()),
    ],
    format: json['format'] as String?,
    architecture: _archLabel(json['arch']),
    author: _extractAuthor(json['repo_id'] as String?),
    paramsB: (json['params_b'] as num?)?.toDouble(),
    likes: (json['likes'] as num?)?.toInt() ?? 0,
    downloads: (json['downloads'] as num?)?.toInt() ?? 0,
    task: json['task'] as String?,
  );

  static String? _archLabel(Object? raw) {
    if (raw is Map) {
      final v = raw['architecture'];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  static String? _extractAuthor(String? repoId) {
    if (repoId == null || repoId.isEmpty) return null;
    final slashIdx = repoId.indexOf('/');
    return slashIdx >= 0 ? repoId.substring(0, slashIdx) : null;
  }
}

List<String> _stringList(Object? raw) => [
  for (final item in (raw as List?) ?? const [])
    if (item is String && item.isNotEmpty) item,
];

/// Parses the raw detail body into a [ModelDetail], or null when the body isn't
/// the expected shape.
ModelDetail? parseModelDetail(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    return ModelDetail.fromJson(decoded.cast<String, dynamic>());
  } on FormatException {
    return null;
  }
}
