import '../../../infrastructure/api/models/grid_overview.dart';
import 'node_display.dart';
import 'node_metrics.dart' show formatCount, formatMetricNumber;

/// One model as the models panel reads it: what it is called, what the grid
/// answered with it, and how many online machines can serve it.
///
/// Assembled once per build by [rankModelUsage] rather than looked up per row:
/// the node count is a scan of every online node's advertised models, and doing
/// that inside a row builder would repeat the scan for each of them.
class ModelUsage {
  const ModelUsage({
    required this.model,
    required this.answered,
    required this.nodes,
  });

  final OverviewModel model;

  /// What this model answered, or null when **nothing measured it** — an older
  /// relay computes no rollup at all. A model that was measured and answered
  /// nothing carries a [NodeAnswered] whose figures are zero, which is a
  /// different and true statement. See [modelAnswered].
  final NodeAnswered? answered;

  /// How many online machines advertise this model. Zero on a model the grid
  /// lists but no node currently serves.
  final int nodes;

  String get id => model.id;

  /// Tokens generated. Zero stands in for "not measured" only for *ordering* —
  /// every figure shown to the reader goes through [answered] so the two stay
  /// distinguishable on screen.
  int get tokensOut => answered?.tokensOut ?? 0;

  /// Tokens read, cached prefill included (see [AnsweredTokens]).
  int get tokensIn => answered?.tokensIn ?? 0;

  int get tokensCached => answered?.tokensCached ?? 0;

  /// Input that was not served from cache — the leg that keeps the three-way
  /// split from double-counting the cached share.
  int get freshInputTokens => answered?.freshInputTokens ?? 0;

  int get requests => answered?.requests ?? 0;

  /// Whether this model has figures worth drawing a bar for. False both for a
  /// model nothing measured and for one measured at zero: neither has a share
  /// of anything.
  bool get isActive => tokensOut > 0 || tokensIn > 0;
}

/// The grid's models ordered by what they actually did, busiest first.
///
/// **Not the relay's order, and not alphabetical.** The list arrives in catalog
/// order, which puts the model carrying four fifths of the grid wherever its
/// name happens to fall — rename it and it moves. Ordered by output, the
/// position itself carries information.
///
/// Ties fall back to requests and then to the id, so a grid whose models have
/// all answered nothing keeps a stable order across polls instead of reshuffling
/// under the pointer.
List<ModelUsage> rankModelUsage({
  required List<OverviewModel> models,
  required Iterable<OverviewNode> nodes,
  required NodeAnswered? gridTotal,
}) {
  final byModel = answeredByModel(nodes);
  final rows = [
    for (final model in models)
      ModelUsage(
        model: model,
        answered: modelAnswered(byModel, model.id, gridTotal: gridTotal),
        nodes: modelNodeCount(nodes, model.id),
      ),
  ];
  rows.sort((a, b) {
    final out = b.tokensOut.compareTo(a.tokensOut);
    if (out != 0) return out;
    final requests = b.requests.compareTo(a.requests);
    if (requests != 0) return requests;
    return modelKey(a.id).compareTo(modelKey(b.id));
  });
  return rows;
}

/// How many of [nodes] advertise [modelId].
///
/// Keyed by [modelKey] on both sides: a node advertises the relay's normalised
/// id while the overview's model entry keeps its catalog casing, so a raw `==`
/// counts zero machines for a model half the grid is serving.
///
/// The node's primary [OverviewNode.model] counts too — an older provider fills
/// that and leaves [OverviewNode.models] empty, and reading only the list would
/// report such a node as serving nothing.
int modelNodeCount(Iterable<OverviewNode> nodes, String modelId) {
  final key = modelKey(modelId);
  if (key.isEmpty) return 0;
  var count = 0;
  for (final node in nodes) {
    final serves =
        node.models.any((m) => modelKey(m) == key) ||
        modelKey(node.model ?? '') == key;
    if (serves) count++;
  }
  return count;
}

/// A model id split into the three parts a narrow column has to treat
/// differently: the provider prefix that repeats down the list, the middle that
/// may be shortened, and the tail that must survive.
///
/// **Plain ellipsis cuts the wrong end.** A model id keeps what distinguishes it
/// at the back — `NVIDIA-Nemotron-3.5-Lightning-3B-v2` ellipsized from the right
/// loses the size and the version and leaves the half every such id shares. The
/// tail is the last whole hyphen-segments that fit in [_maxTail], so what gets
/// dropped is the descriptive middle, which is also the part a reader can guess.
///
/// A short id splits into head alone: pinning a tail on a name that was never
/// going to be shortened only invites a break in the middle of a word.
({String org, String head, String tail}) splitModelId(String id) {
  final slash = id.indexOf('/');
  final org = slash < 0 ? '' : id.substring(0, slash + 1);
  final rest = id.substring(org.length);
  if (rest.length <= _minToShorten) return (org: org, head: rest, tail: '');
  final segments = rest.split('-');
  var tail = '';
  // Never the whole thing: a tail that swallowed every segment would leave an
  // empty head, and the row would have nothing left to shorten.
  for (var i = segments.length - 1; i > 0; i--) {
    final next = '-${segments[i]}$tail';
    if (next.length > _maxTail) break;
    tail = next;
  }
  return (
    org: org,
    head: rest.substring(0, rest.length - tail.length),
    tail: tail,
  );
}

/// Below this an id fits any column the app puts it in, so it is left whole.
const int _minToShorten = 16;

/// How much of an id is worth pinning. Two short segments — a size and a
/// version — and no more: a long tail eats the head it was meant to protect.
const int _maxTail = 8;

/// This model's share of everything the grid generated, as a fraction, or null
/// when the grid generated nothing — a share of zero is undefined, not 0%.
double? outputShare(ModelUsage row, int gridTokensOut) {
  if (gridTokensOut <= 0) return null;
  return row.tokensOut / gridTokensOut;
}

/// A share as a percentage, never rounded to a lie.
///
/// A model at 0.4% of the grid rounds to `0%` under plain integer rounding,
/// which reads as "did nothing" against a row that plainly shows 24.6K tokens.
/// Below 1% the figure keeps a decimal, and anything that would still round to
/// zero says `<0.1%` instead.
String formatShare(double fraction) {
  final pct = fraction * 100;
  if (pct >= 9.95) return '${pct.round()}%';
  if (pct >= 0.95) return '${formatMetricNumber(pct)}%';
  if (pct >= 0.05) return '${pct.toStringAsFixed(1)}%';
  return pct > 0 ? '<0.1%' : '0%';
}

/// What share of the input this model read came out of a prompt cache, or null
/// when it read nothing.
///
/// Worth its own line because a cold cache and a warm one bill differently for
/// the same work: cached prefill is nearly free, so a grid at 62% is paying
/// full price for a third of what it reads.
String? cacheHitLabel(NodeAnswered? answered) {
  final total = answered?.tokensIn ?? 0;
  if (answered == null || total <= 0) return null;
  return 'cache hit ${formatShare(answered.tokensCached / total)}';
}

/// Average tokens generated per request, or null when nothing was answered.
///
/// The one figure that separates "8.4K short replies" from "8.4K long ones",
/// which neither the token count nor the request count can say alone.
String? tokensPerRequestLabel(NodeAnswered? answered) {
  final requests = answered?.requests ?? 0;
  if (answered == null || requests <= 0) return null;
  return '~${formatCount(answered.tokensOut ~/ requests)} tok/req';
}

/// How many machines serve this model, as a phrase — null at zero, where the
/// honest reading is that the grid lists a model nothing currently runs, and a
/// `0 nodes` beside live token figures would contradict them.
String? nodeCountLabel(ModelUsage row) {
  if (row.nodes <= 0) return null;
  return '${row.nodes} ${row.nodes == 1 ? 'node' : 'nodes'}';
}

/// The hero's footnote: cache, speed and reach, in that order, dropping
/// whatever this model cannot say. Empty when it can say none of them.
String heroDetailLine(ModelUsage row) => [
  ?cacheHitLabel(row.answered),
  ?tokensPerRequestLabel(row.answered),
  ?nodeCountLabel(row),
].join(' · ');
