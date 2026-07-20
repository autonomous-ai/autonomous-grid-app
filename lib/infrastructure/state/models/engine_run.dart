/// How an engine in a machine's union serves — derived from its record fields,
/// so the UI can label and icon each one (a local model vs a hosted API vs an
/// external server you point at).
enum EngineKind {
  /// The built-in llama.cpp engine serving a local GGUF.
  local,

  /// An OpenAI-compatible server on this machine the engine points at (Ollama,
  /// LM Studio, your own) — it carries an `endpoint_url`.
  external,

  /// A hosted provider served through the vendor (OpenAI key, ChatGPT/Codex
  /// subscription) — it carries an `api_kind`.
  api,
}

/// One engine inside a machine's per-grid union (`engines[]` in `remote.json`).
/// A machine has a single `remote` identity per grid but serves the *union* of
/// every `grid join` it ran (ADR 0010), so a record holds one of these per
/// joined engine — that's what lets the UI list them and stop one at a time.
class EngineSpec {
  const EngineSpec({required this.models, this.apiKind, this.endpointUrl});

  final List<String> models;

  /// Hosted-provider kind (`openai`, `codex`) when this is an API engine.
  final String? apiKind;

  /// The OpenAI-compatible URL this engine points at, when it's external.
  final String? endpointUrl;

  EngineKind get kind {
    if (apiKind != null && apiKind!.isNotEmpty) return EngineKind.api;
    if (endpointUrl != null && endpointUrl!.isNotEmpty) {
      return EngineKind.external;
    }
    return EngineKind.local;
  }

  /// The value `grid leave --engine <selector>` matches on to drop just this
  /// engine from the union: its endpoint URL when external (exact match), else
  /// its first served model (`match_engine` matches a served model too — the
  /// gguf name for local, the namespaced `codex:`/`openai:` name for API).
  /// Null when the spec carries nothing to match on.
  String? get leaveSelector {
    if (endpointUrl != null && endpointUrl!.isNotEmpty) return endpointUrl;
    return models.isEmpty ? null : models.first;
  }

  factory EngineSpec.fromJson(Map<String, dynamic> json) => EngineSpec(
    models: _stringList(json['models']),
    apiKind: json['api_kind'] is String ? json['api_kind'] as String : null,
    endpointUrl: json['endpoint_url'] is String
        ? json['endpoint_url'] as String
        : null,
  );
}

/// One engine's run record, written by the CLI when `grid join` launches a
/// detached engine — `~/.grid/run/engines/<grid_id>/<engine_id>.json`. The app
/// reads it to tell whether an engine is still serving a grid after a restart,
/// and to list the union of engines the machine serves. Mirrors the fields the
/// CLI persists; unknown fields are ignored.
class EngineRunRecord {
  const EngineRunRecord({
    required this.engineId,
    required this.gridId,
    required this.models,
    required this.pid,
    this.engines = const [],
    this.endpointPort,
  });

  final String engineId;
  final String gridId;

  /// The flat union of every advertised model the machine serves on this grid.
  final List<String> models;

  /// OS process id of the detached `grid join` engine, used to probe liveness.
  /// Null when the record predates pid tracking or is malformed.
  final int? pid;

  /// The union broken out per engine, so the UI can show and stop each one. When
  /// a record predates `engines[]` it falls back to a single synthesized spec
  /// from the flat fields, so an older record still lists as one engine.
  final List<EngineSpec> engines;

  /// The local built-in engine's OpenAI server port, when one is serving — lets
  /// the Playground hit it directly for a smoke test without parsing the log.
  final int? endpointPort;

  factory EngineRunRecord.fromJson(Map<String, dynamic> json) {
    final models = _stringList(json['models']);
    final rawEngines = json['engines'];
    final engines = rawEngines is List && rawEngines.isNotEmpty
        ? [
            for (final entry in rawEngines)
              if (entry is Map)
                EngineSpec.fromJson(Map<String, dynamic>.from(entry)),
          ]
        : [
            EngineSpec(
              models: models,
              apiKind: json['api_kind'] is String
                  ? json['api_kind'] as String
                  : null,
              endpointUrl: json['endpoint_url'] is String
                  ? json['endpoint_url'] as String
                  : null,
            ),
          ];
    return EngineRunRecord(
      engineId: (json['engine_id'] ?? '') as String,
      gridId: (json['grid_id'] ?? '') as String,
      models: models,
      pid: json['pid'] is int ? json['pid'] as int : null,
      engines: engines,
      endpointPort: json['endpoint_port'] is int
          ? json['endpoint_port'] as int
          : null,
    );
  }
}

List<String> _stringList(Object? value) =>
    value is List ? value.map((e) => e.toString()).toList() : const [];
