/// Which models actually served a turn, and in what proportion.
///
/// A turn sent as `auto` is a routing instruction, not a model: the grid picks
/// one per request, and a long agent turn is many requests. A turn sent to a
/// *named* model fans out too — Claude Code is handed a lead model, a small/fast
/// one for side work and a subagent one, which on a grid serving tiers are three
/// different models. Either way the footer used to name one model and be wrong.
///
/// Pure: the numbers come from `GET /relay/v1/usage`, and everything here is
/// arithmetic and formatting over them, so it is testable without a grid.
library;

/// One model's share of a turn.
class ModelShare {
  const ModelShare({
    required this.model,
    required this.requests,
    this.tokensIn = 0,
    this.tokensOut = 0,
  });

  /// The model that served, as the grid names it — already the ROUTED model, not
  /// the `auto` the request carried.
  final String model;

  /// How many relay calls it answered.
  final int requests;

  final int tokensIn;
  final int tokensOut;

  Map<String, Object?> toJson() => {
    'model': model,
    'requests': requests,
    if (tokensIn > 0) 'tokens_in': tokensIn,
    if (tokensOut > 0) 'tokens_out': tokensOut,
  };

  static ModelShare? fromJson(Object? json) {
    if (json is! Map) return null;
    final model = json['model'];
    final requests = json['requests'];
    if (model is! String || model.isEmpty) return null;
    if (requests is! int || requests <= 0) return null;
    return ModelShare(
      model: model,
      requests: requests,
      tokensIn: json['tokens_in'] is int ? json['tokens_in'] as int : 0,
      tokensOut: json['tokens_out'] is int ? json['tokens_out'] as int : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ModelShare &&
      other.model == model &&
      other.requests == requests &&
      other.tokensIn == tokensIn &&
      other.tokensOut == tokensOut;

  @override
  int get hashCode => Object.hash(model, requests, tokensIn, tokensOut);
}

/// Below this many requests the footer shows counts, not percentages.
///
/// At ten requests one call is 10%, so the first percentage shown is never finer
/// than the data behind it. `67% · 33%` off three calls reads as a measurement
/// when it is really "two and one".
const int kPercentFloor = 10;

/// How many models the footer names before it stops counting them out.
const int kNamedModels = 3;

/// Whole percentages that sum to exactly 100, by largest remainder.
///
/// Rounding each share on its own gives 33/33/33 and leaves the reader to wonder
/// where the last percent went. The remainder method hands those spare points to
/// the shares that lost the most in the rounding, which is both the standard
/// answer and the one that keeps the biggest share biggest.
List<int> percentages(List<ModelShare> shares) {
  final total = shares.fold(0, (sum, s) => sum + s.requests);
  if (total <= 0) return [for (final _ in shares) 0];
  final exact = [for (final s in shares) s.requests * 100 / total];
  final floors = [for (final value in exact) value.floor()];
  var left = 100 - floors.fold(0, (sum, value) => sum + value);
  // Biggest remainder first; ties go to the bigger share, then to the earlier
  // one, so the same input always renders the same way.
  final order = [for (var i = 0; i < shares.length; i++) i]
    ..sort((a, b) {
      final byRemainder = (exact[b] - floors[b]).compareTo(
        exact[a] - floors[a],
      );
      if (byRemainder != 0) return byRemainder;
      final bySize = shares[b].requests.compareTo(shares[a].requests);
      return bySize != 0 ? bySize : a.compareTo(b);
    });
  for (final index in order) {
    if (left <= 0) break;
    floors[index]++;
    left--;
  }
  return floors;
}

/// The footer's phrase for [shares], or null when there is nothing to say.
///
/// Shows from the FIRST request rather than waiting for a second model: on a
/// long turn the caption is the only place the user can see what `auto` is
/// spending, and staying blank until a second model happens to appear left it
/// silent through the opening minute.
///
/// Null — not an empty string — only when the phrase would add nothing: no
/// requests recorded (an agent answering from its own cache makes no grid
/// calls), or one model that answered once, where `×1` is a longer way to write
/// the model name the caller already has.
///
/// **A lone model is always counted, never percented.** It would read `100%`
/// whatever it did, and a percentage with nothing to compare against invents a
/// precision the line does not have.
///
/// [label] renders the model id the way the rest of the app does; passing it in
/// keeps this file free of the display layer.
String? modelShareLabel(
  List<ModelShare> shares, {
  required String Function(String) label,
}) {
  final ranked = rankedShares(shares);
  if (ranked.isEmpty) return null;
  final total = ranked.fold(0, (sum, s) => sum + s.requests);
  if (ranked.length == 1 && total == 1) return null;
  final named = ranked.take(kNamedModels).toList();
  final rest = ranked.length - named.length;
  final parts = <String>[];
  if (ranked.length > 1 && total >= kPercentFloor) {
    final percents = percentages(ranked);
    for (var i = 0; i < named.length; i++) {
      parts.add('${label(named[i].model)} ${percents[i]}%');
    }
  } else {
    for (final share in named) {
      parts.add('${label(share.model)} ×${share.requests}');
    }
  }
  if (rest > 0) parts.add('+$rest more');
  return parts.join(' · ');
}

/// [shares] with empty rows dropped and the busiest first.
///
/// Sorted here rather than trusted from the wire: the endpoint already orders by
/// request count, but a caption that silently reorders itself when a server
/// changes is worse than one that sorts for itself.
List<ModelShare> rankedShares(List<ModelShare> shares) =>
    [
      for (final s in shares)
        if (s.requests > 0) s,
    ]..sort((a, b) {
      final byRequests = b.requests.compareTo(a.requests);
      return byRequests != 0 ? byRequests : a.model.compareTo(b.model);
    });

/// The hover line: every model, with its count and what it read.
///
/// The footer names at most [kNamedModels]; this is where the rest of them live,
/// so "+2 more" is never the end of the story.
String modelShareDetail(
  List<ModelShare> shares, {
  required String Function(String) label,
}) {
  final ranked = rankedShares(shares);
  final total = ranked.fold(0, (sum, s) => sum + s.requests);
  final requests = total == 1 ? '1 request' : '$total requests';
  final models = ranked.length == 1 ? '1 model' : '${ranked.length} models';
  return [
    'Answered by $models across $requests:',
    for (final share in ranked)
      '  ${label(share.model)} — '
          '${share.requests == 1 ? '1 request' : '${share.requests} requests'}',
  ].join('\n');
}
