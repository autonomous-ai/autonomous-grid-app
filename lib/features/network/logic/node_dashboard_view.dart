/// What the node dashboard is showing: which machines, in what order.
///
/// Pure ordering and narrowing, plus the one provider that remembers the
/// choice — so the dialog stays a renderer and every rule below is unit tested
/// rather than eyeballed against a live grid.
///
/// **An unreported reading is not a zero, and never sorts like one.** A relay
/// too old to compute the answered rollup sends `null` for every node on the
/// grid, and a node that has served nothing since it came up reports no
/// throughput. Sorting those as `0` would file a machine nobody has measured in
/// among the machines that were measured and found idle — the same libel
/// `node_metrics.dart` exists to prevent, arriving through the back door as an
/// ordering instead of a label. Unmeasured nodes sink to the bottom of every
/// descending sort, as a group, below the real zeros.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import 'grid_power_provider.dart' show sortNodesByPower;
import 'node_display.dart'
    show kAutoModelId, mediaCapabilityLabel, modelKey, nodePlatformLabel;

/// The orders the dashboard can be read in.
///
/// Each one answers a different question about the same fleet, which is why
/// there is more than one: *output tokens* and *requests* both ask "who is
/// carrying the grid" and disagree — a node with three enormous replies and one
/// with three hundred short ones swap places between them. *Speed* asks how fast
/// a machine answers rather than how much it answered, so an idle fast box ranks
/// above a busy slow one. *Memory* asks what a machine could take on. *Name* asks
/// nothing and is the one order that doesn't move under you while you read.
enum NodeSortKey { outputTokens, requests, throughput, memory, name }

/// The menu label for each order — the sort button prints this too, so the
/// button and the ticked row can never word the same choice differently.
String nodeSortLabel(NodeSortKey key) => switch (key) {
  NodeSortKey.outputTokens => 'Output tokens',
  NodeSortKey.requests => 'Requests',
  NodeSortKey.throughput => 'Speed',
  NodeSortKey.memory => 'Memory',
  NodeSortKey.name => 'Name',
};

/// The one-line note under each order, saying what it actually ranks by — the
/// window included, because "Output tokens" without it reads as all-time.
String nodeSortDetail(NodeSortKey key) => switch (key) {
  NodeSortKey.outputTokens => 'Most tokens generated in the last 24h',
  NodeSortKey.requests => 'Most requests answered in the last 24h',
  NodeSortKey.throughput => 'Fastest measured decode rate',
  // Both words, because the cards print both: a machine's pool is "RAM" on
  // Apple Silicon and "VRAM" on a discrete GPU (see `nodeMemoryKind`), and a
  // menu naming only one of them reads as sorting only those machines.
  NodeSortKey.memory => 'Most RAM or VRAM',
  NodeSortKey.name => 'A to Z',
};

/// One dashboard's worth of "show me these, in this order".
///
/// Held whole rather than as three loose providers: the header has to say
/// "3 of 9" and the empty state has to offer to undo whatever caused it, and
/// both need to read the sort and the filters as one answer.
class NodeDashboardView {
  const NodeDashboardView({
    this.sort = NodeSortKey.outputTokens,
    this.model,
    this.platform,
  });

  /// The order the cards are laid out in. Defaults to output tokens: the
  /// dashboard is opened to find out who is doing the work, so the machine doing
  /// the most of it should not be somewhere in the middle of the third row.
  final NodeSortKey sort;

  /// Show only machines serving this model, in [modelKey] form. Null shows all.
  final String? model;

  /// Show only machines on this OS — the label [nodePlatformLabel] produces
  /// ("macOS" / "Linux" / "Windows"). Null shows all.
  final String? platform;

  /// Whether anything is being hidden. The sort is deliberately not part of
  /// this: reordering a list hides nothing, and an empty result can only ever
  /// be a filter's doing.
  bool get isFiltered => model != null || platform != null;

  NodeDashboardView sortedBy(NodeSortKey key) =>
      NodeDashboardView(sort: key, model: model, platform: platform);

  /// Pass null to clear — hence a method per field rather than one `copyWith`,
  /// which cannot tell "leave it alone" from "set it to null" without a
  /// sentinel.
  NodeDashboardView showingModel(String? id) => NodeDashboardView(
    sort: sort,
    model: id == null ? null : modelKey(id),
    platform: platform,
  );

  NodeDashboardView showingPlatform(String? label) =>
      NodeDashboardView(sort: sort, model: model, platform: label);

  /// Everything back, same order. The empty state's way out.
  NodeDashboardView get unfiltered => NodeDashboardView(sort: sort);

  @override
  bool operator ==(Object other) =>
      other is NodeDashboardView &&
      other.sort == sort &&
      other.model == model &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(sort, model, platform);
}

/// Every model the grid's machines advertise, deduplicated and ordered for a
/// menu.
///
/// `auto` is dropped: it is the relay's virtual router (see [kAutoModelId]), not
/// something a machine serves, so filtering by it would ask for the nodes behind
/// every model at once and return an arbitrary subset.
///
/// Keyed by [modelKey] because the same model reaches the app cased three
/// different ways, but the **first spelling seen wins** for display — a menu
/// listing `qwen/qwen3.8-27b` should print it the way its node advertises it,
/// not lowercased into something nobody typed.
List<String> nodeDashboardModels(Iterable<OverviewNode> nodes) {
  final seen = <String, String>{};
  for (final node in nodes) {
    for (final id in _advertised(node)) {
      final key = modelKey(id);
      if (key.isEmpty || key == kAutoModelId) continue;
      seen.putIfAbsent(key, () => id);
    }
  }
  final ids = seen.values.toList()
    ..sort(
      (a, b) =>
          modelLabel(a).toLowerCase().compareTo(modelLabel(b).toLowerCase()),
    );
  return ids;
}

/// What a model id is called in the menu — a media capability by its human name
/// ("Image generation"), everything else by the id its node advertises.
String modelLabel(String id) => mediaCapabilityLabel(id) ?? id;

/// What to call the model a filter is set to, given the ids the grid currently
/// advertises.
///
/// Falls back to the key itself when no node advertises it any more — the
/// machine serving it went offline while the filter was set. The button has to
/// keep naming it: dropping back to "All models" would say the dashboard is
/// showing everything at the moment it is showing nothing, which is the one
/// reading that leaves a user with no idea what happened.
String modelLabelForKey(List<String> models, String key) {
  for (final id in models) {
    if (modelKey(id) == key) return modelLabel(id);
  }
  return key;
}

/// The operating systems present on the grid, as menu labels, alphabetically.
///
/// Only the ones actually here: a grid of Macs offers "macOS" alone rather than
/// three rows, two of which would empty the dashboard. Nodes whose relay is too
/// old to report a platform contribute nothing and are addressed in
/// [applyNodeDashboardView].
List<String> nodeDashboardPlatforms(Iterable<OverviewNode> nodes) {
  final labels = <String>{
    for (final node in nodes) ?nodePlatformLabel(node.platform),
  }.toList();
  labels.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return labels;
}

/// Everything a node says it can answer — its advertised list, or its primary
/// model when the list is empty.
Iterable<String> _advertised(OverviewNode node) => node.models.isNotEmpty
    ? node.models
    : [if ((node.model ?? '').isNotEmpty) node.model!];

/// The nodes [view] asks for, in the order it asks for.
///
/// A node the filter excludes is gone, not greyed: the dashboard levels its rows
/// by height and a row of disabled cards would cost the same space as the
/// machines the reader asked to see.
///
/// A node that reported no platform is excluded by *any* platform filter rather
/// than passed through. The alternative — treating "didn't say" as a match — puts
/// a machine under a heading it may not belong to, and the reader has no way to
/// tell which rows were guesses.
List<OverviewNode> applyNodeDashboardView(
  List<OverviewNode> nodes,
  NodeDashboardView view,
) {
  final kept = [
    for (final node in nodes)
      if (_matches(node, view)) node,
  ];
  return sortNodes(kept, view.sort);
}

bool _matches(OverviewNode node, NodeDashboardView view) {
  final model = view.model;
  if (model != null && !_advertised(node).any((id) => modelKey(id) == model)) {
    return false;
  }
  final platform = view.platform;
  return platform == null || nodePlatformLabel(node.platform) == platform;
}

/// [nodes] in [key] order, as a new list — the caller's is left alone because it
/// comes straight out of a provider.
///
/// Every order is total and stable: ties fall back to the name, so a dashboard
/// polling every few seconds doesn't shuffle two equal machines past each other
/// while someone is reading them.
List<OverviewNode> sortNodes(List<OverviewNode> nodes, NodeSortKey key) {
  if (key == NodeSortKey.memory) return sortNodesByPower(nodes);
  final sorted = [...nodes];
  if (key == NodeSortKey.name) {
    sorted.sort(_byName);
    return sorted;
  }
  final value = switch (key) {
    NodeSortKey.outputTokens => (OverviewNode n) => n.answered?.tokensOut,
    NodeSortKey.requests => (OverviewNode n) => n.answered?.requests,
    _ => (OverviewNode n) => _throughput(n),
  };
  sorted.sort((a, b) => _byValueDesc(a, b, value));
  return sorted;
}

/// A node's decode rate, with a non-positive reading read as *unmeasured*.
///
/// `throughputLabel` already prints `0` as `—`: the relay advertises a rate only
/// once the node has served a request it could time, so a zero there is the
/// absence of a measurement wearing a number. Sorting has to agree with the
/// label, or a card reading "— tok/s" would rank above one reading "1".
num? _throughput(OverviewNode node) {
  final tokS = node.throughputTokS;
  return tokS == null || tokS <= 0 ? null : tokS;
}

/// Biggest first, with everything unmeasured after everything measured — and the
/// name breaking every tie, including the tie between two unmeasured nodes.
int _byValueDesc(
  OverviewNode a,
  OverviewNode b,
  num? Function(OverviewNode) of,
) {
  final av = of(a);
  final bv = of(b);
  if (av == null && bv == null) return _byName(a, b);
  if (av == null) return 1;
  if (bv == null) return -1;
  final byValue = bv.compareTo(av);
  return byValue != 0 ? byValue : _byName(a, b);
}

/// Case-insensitively by name, falling back to the raw name so two machines
/// differing only in case still get a fixed order instead of swapping places
/// between polls.
int _byName(OverviewNode a, OverviewNode b) {
  final byLower = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byLower != 0 ? byLower : a.name.compareTo(b.name);
}

/// The line under the dashboard's title: how many machines are serving, and —
/// only while a filter is hiding some — how many of them are on screen.
///
/// The ratio appears only when it says something. Unfiltered it would read "9 of
/// 9" on every grid, which trains the eye to skip the line that is supposed to
/// warn it that cards are missing.
///
/// The noun agrees with [total], not [shown], so a filter that matches one
/// machine on a nine-machine grid reads "1 of 9 machines" rather than "1 of 9
/// machine".
String nodeDashboardSubtitle(int total, int shown) {
  if (total <= 0) return 'No machines are serving this grid right now.';
  final noun = total == 1 ? 'machine' : 'machines';
  final count = shown == total ? '$total $noun' : '$shown of $total $noun';
  return '$count serving · readings refresh with the grid overview';
}

/// The dashboard's sort and filters, remembered for as long as the app runs.
///
/// Not `autoDispose`: the dialog is the only listener, so disposing with it
/// would reset the choice every time it is closed — and someone who sorted by
/// requests to find the busy machine is reopening this to look at that same
/// machine again.
final nodeDashboardViewProvider =
    NotifierProvider<NodeDashboardViewNotifier, NodeDashboardView>(
      NodeDashboardViewNotifier.new,
    );

class NodeDashboardViewNotifier extends Notifier<NodeDashboardView> {
  @override
  NodeDashboardView build() => const NodeDashboardView();

  void sortBy(NodeSortKey key) => state = state.sortedBy(key);

  /// Null clears the model filter.
  void showModel(String? id) => state = state.showingModel(id);

  /// Null clears the platform filter.
  void showPlatform(String? label) => state = state.showingPlatform(label);

  void clearFilters() => state = state.unfiltered;
}
