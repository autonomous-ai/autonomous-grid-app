/// One engine's run record, written by the CLI when `grid join` launches a
/// detached engine — `~/.grid/run/engines/<grid_id>/<engine_id>.json`. The app
/// reads it to tell whether an engine is still serving a grid after a restart.
/// Mirrors the fields the CLI persists; unknown fields are ignored.
class EngineRunRecord {
  const EngineRunRecord({
    required this.engineId,
    required this.gridId,
    required this.models,
    required this.pid,
  });

  final String engineId;
  final String gridId;
  final List<String> models;

  /// OS process id of the detached `grid join` engine, used to probe liveness.
  /// Null when the record predates pid tracking or is malformed.
  final int? pid;

  factory EngineRunRecord.fromJson(Map<String, dynamic> json) =>
      EngineRunRecord(
        engineId: (json['engine_id'] ?? '') as String,
        gridId: (json['grid_id'] ?? '') as String,
        models: json['models'] is List
            ? (json['models'] as List).map((e) => e.toString()).toList()
            : const [],
        pid: json['pid'] is int ? json['pid'] as int : null,
      );
}
