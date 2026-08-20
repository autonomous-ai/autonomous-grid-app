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
  });

  final RoutingMode mode;
  final bool isFixed;
  final List<String>? models; // brute force only
  final String? worker; // judge loop only
  final String? judge; // judge loop only

  /// The exact string sent as the chat request's `model` field.
  String toModelField() {
    if (!isFixed) return routingModelId(mode);
    if (mode == RoutingMode.bruteForce) {
      return jsonEncode({'mode': 'brute_force', 'models': models});
    }
    return jsonEncode({'mode': 'judge_loop', 'worker': worker, 'judge': judge});
  }

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'mode': mode.wireValue,
    'isFixed': isFixed,
    if (models != null) 'models': models,
    if (worker != null) 'worker': worker,
    if (judge != null) 'judge': judge,
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
    return RoutingGroup(
      mode: mode,
      isFixed: isFixed,
      models: rawModels is List ? rawModels.whereType<String>().toList() : null,
      worker: json['worker'] is String ? json['worker'] as String : null,
      judge: json['judge'] is String ? json['judge'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoutingGroup &&
      other.mode == mode &&
      other.isFixed == isFixed &&
      _listEq(other.models, models) &&
      other.worker == worker &&
      other.judge == judge;

  @override
  int get hashCode => Object.hash(
    mode,
    isFixed,
    Object.hashAll(models ?? const []),
    worker,
    judge,
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

/// Result of parsing the grid's free-text answer to a suggestion probe.
sealed class SuggestionParseResult {}

/// A successfully parsed routing group suggestion.
class SuggestionParsed extends SuggestionParseResult {
  SuggestionParsed(this.group);
  final RoutingGroup group;
}

/// A failed parsing attempt with a human-readable reason.
class SuggestionParseFailed extends SuggestionParseResult {
  SuggestionParseFailed(this.reason);
  final String reason;
}

/// Extracts the suggested [RoutingGroup] from a model's free-text answer to
/// the suggestion probe (see design spec §3) — tolerant of prose or a
/// markdown code fence wrapped around the JSON object.
SuggestionParseResult parseSuggestion(String assistantText, RoutingMode mode) {
  final match = RegExp(r'\{[\s\S]*\}').firstMatch(assistantText);
  if (match == null) {
    return SuggestionParseFailed('No JSON object found in the answer.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(match.group(0)!);
  } on FormatException catch (e) {
    return SuggestionParseFailed('Could not parse JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    return SuggestionParseFailed('Answer was not a JSON object.');
  }
  if (mode == RoutingMode.bruteForce) {
    final rawModels = decoded['models'];
    if (rawModels is! List || rawModels.length < 2) {
      return SuggestionParseFailed(
        'Expected a "models" list with at least 2 entries.',
      );
    }
    final models = rawModels.whereType<String>().toList();
    if (models.length != rawModels.length) {
      return SuggestionParseFailed('"models" contained a non-string entry.');
    }
    return SuggestionParsed(
      RoutingGroup(mode: mode, isFixed: true, models: models),
    );
  }
  final worker = decoded['worker'];
  final judge = decoded['judge'];
  if (worker is! String || judge is! String) {
    return SuggestionParseFailed(
      'Expected string "worker" and "judge" fields.',
    );
  }
  return SuggestionParsed(
    RoutingGroup(mode: mode, isFixed: true, worker: worker, judge: judge),
  );
}
