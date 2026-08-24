import 'dart:convert';

/// Which orchestrator pattern a chat is routed through.
enum RoutingMode {
  bruteForce('brute_force', 'Brute Force'),
  judgeLoop('judge_loop', 'Feedback Loop');

  const RoutingMode(this.wireValue, this.displayName);
  final String wireValue;
  final String displayName;
}

/// The plain `model` field value that asks the grid for [mode] without pinning
/// any models — the slash string the relay has always accepted, and what
/// Dynamic mode puts on the wire every turn.
///
/// Also the id the chat's model picker gives the mode's row, so a mode is
/// picked, remembered and restored through exactly the same path an ordinary
/// model is.
String routingModelId(RoutingMode mode) => 'auto/${mode.wireValue}';

/// The one-line promise each half of the Pinned/Dynamic choice makes.
///
/// Shared so the picker's mode menu and the setup dialog's segmented control
/// can never drift into describing the same choice two different ways — they
/// are the same question asked at two moments.
///
/// Names "the grid" as the one doing the re-picking — "Re-picked every
/// message" on its own reads as an instruction to the user (as if they had
/// to choose again by hand each time), when the whole point of Dynamic is
/// that nobody has to.
String routingHoldNote({required bool isFixed}) => isFixed
    ? 'Same models every message.'
    : 'The grid picks new models every message.';

/// The routing mode [id] names, or null when it is an ordinary model id.
RoutingMode? routingModeForModelId(String id) {
  final trimmed = id.trim();
  for (final mode in RoutingMode.values) {
    if (routingModelId(mode) == trimmed) return mode;
  }
  return null;
}

/// The models a chat sends to the relay for its routing mode, and whether
/// that pick is pinned (Fixed) or re-picked by the grid every turn (Dynamic).
class RoutingGroup {
  const RoutingGroup({
    required this.mode,
    required this.isFixed,
    this.models,
    this.worker,
    this.judge,
    this.aggregator,
    this.maxRounds,
    this.maxProposers,
    this.pool,
  });

  final RoutingMode mode;
  final bool isFixed;
  final List<String>? models; // brute force, Fixed only
  final String? worker; // judge loop, Fixed only
  final String? judge; // judge loop, Fixed only

  /// Brute Force only, and always optional — the relay picks the aggregator
  /// live from its own ranking (`aggregator_model`, CLI side) whenever this
  /// is null, which is the reasoned default. Only set when the user
  /// explicitly names one in the setup dialog.
  final String? aggregator;

  /// Judge Loop only: the max number of worker/judge rounds (1–10). Null sends
  /// no cap, so the relay uses its own MAX_ROUNDS=5. Applies to BOTH Fixed and
  /// Dynamic — the user asked for a per-chat round bound regardless of pinning.
  final int? maxRounds;

  /// Brute Force, Dynamic only: the max number of proposers the grid may fan
  /// out to. Null leaves it unbounded (the grid uses whatever is free).
  final int? maxProposers;

  /// Brute Force, Dynamic only: the candidate models the grid may draw its
  /// proposers from. Null = the whole grid.
  final List<String>? pool;

  /// The exact string sent as the chat request's `model` field.
  String toModelField() {
    switch (mode) {
      case RoutingMode.bruteForce:
        if (isFixed) {
          return jsonEncode({
            'mode': 'brute_force',
            'models': models,
            if (aggregator != null) 'aggregator': aggregator,
          });
        }
        final hasConfig = maxProposers != null || (pool != null && pool!.isNotEmpty);
        if (!hasConfig) return routingModelId(mode);
        return jsonEncode({
          'mode': 'brute_force',
          'dynamic': true,
          if (maxProposers != null) 'max_proposers': maxProposers,
          if (pool != null && pool!.isNotEmpty) 'pool': pool,
        });
      case RoutingMode.judgeLoop:
        final hasPool = pool != null && pool!.isNotEmpty;
        if (!isFixed && !hasPool && maxRounds == null) return routingModelId(mode);
        return jsonEncode({
          'mode': 'judge_loop',
          if (!isFixed) 'dynamic': true,
          // The Feedback Loop setup now sends a candidate POOL the grid picks
          // worker + judge from. The legacy worker/judge pair is kept only for
          // pinned groups saved by an older build.
          if (isFixed && worker != null) 'worker': worker,
          if (isFixed && judge != null) 'judge': judge,
          if (hasPool) 'pool': pool,
          if (maxRounds != null) 'max_rounds': maxRounds,
        });
    }
  }

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'mode': mode.wireValue,
    'isFixed': isFixed,
    if (models != null) 'models': models,
    if (worker != null) 'worker': worker,
    if (judge != null) 'judge': judge,
    if (aggregator != null) 'aggregator': aggregator,
    if (maxRounds != null) 'maxRounds': maxRounds,
    if (maxProposers != null) 'maxProposers': maxProposers,
    if (pool != null) 'pool': pool,
  };

  /// Safely deserializes from a JSON map, returning null on invalid input.
  static RoutingGroup? tryFromJson(Map<String, dynamic> json) {
    final modeValue = json['mode'];
    final mode = RoutingMode.values
        .where((m) => m.wireValue == modeValue)
        .firstOrNull;
    if (mode == null) return null;
    final isFixed = json['isFixed'];
    if (isFixed is! bool) return null;
    final rawModels = json['models'];
    final rawPool = json['pool'];
    return RoutingGroup(
      mode: mode,
      isFixed: isFixed,
      models: rawModels is List ? rawModels.whereType<String>().toList() : null,
      worker: json['worker'] is String ? json['worker'] as String : null,
      judge: json['judge'] is String ? json['judge'] as String : null,
      aggregator: json['aggregator'] is String
          ? json['aggregator'] as String
          : null,
      maxRounds: json['maxRounds'] is int ? json['maxRounds'] as int : null,
      maxProposers:
          json['maxProposers'] is int ? json['maxProposers'] as int : null,
      pool: rawPool is List ? rawPool.whereType<String>().toList() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoutingGroup &&
      other.mode == mode &&
      other.isFixed == isFixed &&
      _listEq(other.models, models) &&
      other.worker == worker &&
      other.judge == judge &&
      other.aggregator == aggregator;

  @override
  int get hashCode => Object.hash(
    mode,
    isFixed,
    Object.hashAll(models ?? const []),
    worker,
    judge,
    aggregator,
  );
}

bool _listEq(List<String>? a, List<String>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

