/// A grid's machines gathered under the person who runs them — pure, so the
/// panel that draws them stays a layout and this stays readable on its own.
///
/// The node list is a column of the same facts repeated: on this grid three
/// rows read `@design`, three read `Apple M2 Ultra · macOS`, and nine read
/// `1 chat model`. Repetition is what made the panel feel dense — it spent its
/// width on the half of every row that was identical to the row above. Grouping
/// states the shared half once, at the top of a block, and leaves each row with
/// only what distinguishes it.
library;

import '../../../infrastructure/api/models/grid_overview.dart';
import 'grid_power_provider.dart' show formatVram, nodeVramGb;
import 'node_display.dart';
import 'node_metrics.dart' show answeredWindowLabel, formatCount;

/// One machine as the panel shows it: the node, and the name it is listed
/// under ([shortenNodeNames] trims the common prefix off a grid's hostnames).
typedef NodeEntry = ({OverviewNode node, String label});

/// The machines one person runs.
class NodeGroup {
  const NodeGroup({
    required this.handle,
    required this.email,
    required this.machines,
  });

  /// The owner as a row shows them — `@design`. Empty when the relay named
  /// nobody, which the panel renders as a headless block rather than as a
  /// person called nothing.
  final String handle;

  /// The address behind [handle], kept for the initial tile so a node's mark is
  /// drawn from the same string the members panel draws its own from.
  final String email;

  /// Strongest first, in the order [gridOnlineNodesProvider] gave them.
  final List<NodeEntry> machines;

  bool get isSingle => machines.length == 1;

  OverviewNode get first => machines.first.node;
}

/// [nodes] gathered by owner, each group in the position of its strongest
/// machine.
///
/// Order is inherited rather than recomputed: the provider already sorts the
/// grid's machines by what they bring, and a group that jumped the queue
/// because its owner happens to run four small boxes would put the wrong block
/// at the top of a panel people read from the top.
///
/// [labels] runs parallel to [nodes] — the display names, computed across the
/// whole list so the same machine reads the same whichever block it lands in.
List<NodeGroup> groupNodesByOwner(
  List<OverviewNode> nodes,
  List<String> labels,
) {
  final order = <String>[];
  final byHandle = <String, List<NodeEntry>>{};
  final emails = <String, String>{};
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    final handle = nodeHostHandle(node);
    // Every unattributed machine falls into one block, not one block each: they
    // have nothing in common to state at the top, so the block is headless and
    // its rows carry their own hardware — see [groupSpecLine].
    final key = handle;
    if (!byHandle.containsKey(key)) {
      order.add(key);
      byHandle[key] = [];
      emails[key] = (node.providerEmail ?? '').trim();
    }
    byHandle[key]!.add((
      node: node,
      label: i < labels.length ? labels[i] : node.name,
    ));
  }
  return [
    for (final key in order)
      NodeGroup(
        handle: key,
        email: emails[key] ?? '',
        machines: byHandle[key]!,
      ),
  ];
}

/// The block's title — the owner, or the machine itself when the group is one
/// machine, because a header and a single row underneath it would print two
/// names to say one thing.
///
/// `@design` for a person with three boxes; `@scholes · 60001` for a person
/// with one. The handle stays in front either way: on a shared grid the first
/// question a row answers is whose machine this is.
String groupTitle(NodeGroup group) {
  if (group.handle.isEmpty) return '';
  if (!group.isSingle) return group.handle;
  return '${group.handle} · ${group.machines.first.label}';
}

/// What the block's machines *are*, said once — `3 × Apple M2 Ultra · macOS`.
///
/// Empty when they are not the same machine, and then each row carries its own
/// hardware instead ([entrySpecLine]): a block claiming one description for two
/// different boxes would be worse than the repetition it replaced.
///
/// A one-machine block spends the line it saved on what that machine serves
/// (`· 16 parallel`), which a multi-machine block cannot state for all of them
/// and drops — the model count was the string this panel printed nine identical
/// times, and it is the Models panel's subject anyway.
String groupSpecLine(NodeGroup group) {
  if (group.handle.isEmpty) return '';
  final first = nodeMachineLine(group.first);
  if (group.machines.any((e) => nodeMachineLine(e.node) != first)) return '';
  if (first.isEmpty) return '';
  if (!group.isSingle) return '${group.machines.length} × $first';
  // A one-machine block has no rows under it, so this line is that machine's
  // row — but only for the description. Its speed goes where every other
  // machine's goes: the meter and figure at the row's right end.
  final serving = nodeServingLine(group.first);
  return serving.isEmpty ? first : '$first · $serving';
}

/// A machine's own hardware, for a row inside a block whose machines disagree.
/// Empty when the block already said it.
String entrySpecLine(NodeGroup group, OverviewNode node) {
  if (group.handle.isNotEmpty && groupSpecLine(group).isNotEmpty) return '';
  return [
    if (nodeMachineLine(node).isNotEmpty) nodeMachineLine(node),
    if (nodeServingLine(node).isNotEmpty) nodeServingLine(node),
  ].join(' · ');
}

/// What the block puts into the pool, added up — `576 GB RAM`.
///
/// Summed rather than listed: three machines of 192 GB are one 576 GB block to
/// anyone deciding whether the grid can hold a model, and three identical
/// figures down a column were three chances to read the same number.
///
/// Falls back to the subscription tier for a block of seats, which bring a plan
/// rather than memory, and to empty for a machine that reported neither —
/// honest, where a `0 GB` would libel a working box.
String groupMemoryLabel(NodeGroup group) {
  var total = 0.0;
  var counted = 0;
  for (final entry in group.machines) {
    if (nodeVramGb(entry.node) case final gb?) {
      total += gb;
      counted++;
    }
  }
  if (counted == 0) return nodePlanLabel(group.first) ?? '';
  // The kind is the machines' own — Apple Silicon's unified memory is RAM, a
  // discrete card's is VRAM — and a block holding both says neither rather than
  // picking one and being wrong about half its rows.
  final kinds = {
    for (final entry in group.machines)
      if (nodeVramGb(entry.node) != null) nodeMemoryKind(entry.node),
  };
  final kind = kinds.length == 1 ? ' ${kinds.first}' : '';
  return '${formatVram(total)}$kind';
}

/// What the block answered in the relay's window — `37.8K tokens · 24h`.
///
/// The figure the rows deliberately do not carry. Split per machine it was nine
/// counts down a column that nobody compares, and drawn per machine — as a rule
/// in the rail, then as a band behind the row — it read first as a bullet and
/// then as a selection. At the owner, in words, it is one number a block.
///
/// Empty when no machine in the block reported a rollup — a relay too old to
/// compute one sends none, and a `0` standing in for "not measured" would read
/// as a block that did nothing.
String groupWorkLabel(NodeGroup group) {
  var total = 0;
  var window = 0;
  var measured = false;
  for (final entry in group.machines) {
    if (entry.node.answered case final answered?) {
      measured = true;
      total += answered.tokensOut;
      window = window == 0 ? answered.windowSeconds : window;
    }
  }
  if (!measured) return '';
  final label = answeredWindowLabel(window);
  final counts = '${formatCount(total)} output tokens';
  return label.isEmpty ? counts : '$counts · $label';
}

/// The right-hand figure on a machine's row: how fast it answers, else the plan
/// behind a subscription seat, else nothing.
///
/// Speed rather than the token count, because the bar beside the name already
/// carries how much: two figures saying the same thing would leave the row
/// with no room for the one it doesn't say.
String entryFigure(OverviewNode node) {
  final speed = node.throughputTokS;
  if (speed != null && speed > 0) return '~${speed.round()} tok/s';
  return nodePlanLabel(node) ?? '';
}

/// The fastest machine on the grid, in tokens a second — what every speed meter
/// is drawn against. Zero when no machine advertised a throughput at all, which
/// draws no meters.
double peakThroughput(List<OverviewNode> nodes) {
  var peak = 0.0;
  for (final node in nodes) {
    final speed = node.throughputTokS;
    if (speed != null && speed > peak) peak = speed;
  }
  return peak;
}

/// How fast this machine is against the fastest on the grid, 0…1 — the fill in
/// the meter beside its figure.
///
/// Speed rather than the work it did, and that is the whole reason a meter can
/// exist here at all. A grid's 24h output spans three orders of magnitude — 2K
/// beside 4.8M — so a linear bar drawn across it is one full row and eight
/// invisible ones, which is what sank the two earlier attempts at charting this
/// panel. Throughput spans a single order (4 tok/s beside 222 on this grid),
/// and that is a range a bar can argue about.
///
/// Null when the machine advertised no throughput. An absent meter, not an
/// empty one: a provider too old to report the field never said it was slow —
/// the same distinction [nodeActivityLine] makes by dropping the figure instead
/// of printing `0 tok/s`.
double? speedShare(OverviewNode node, double peak) {
  final speed = node.throughputTokS;
  if (speed == null || speed <= 0 || peak <= 0) return null;
  return (speed / peak).clamp(0.0, 1.0);
}
