import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../auth/logic/session_controller.dart';
import 'grid_overview_provider.dart';

/// The hardware a grid actually brings to bear, summed across its *online*
/// nodes: GPU memory, how many requests it can serve at once, and how fast.
///
/// Offline nodes are excluded throughout — a machine that is asleep contributes
/// no VRAM and no throughput, and counting it would overstate what the grid can
/// do right now. This is the number a user checks to answer "is this grid strong
/// enough for what I'm about to ask?".
class GridPower {
  const GridPower({
    required this.onlineNodes,
    required this.models,
    this.vramGb,
    this.parallel,
    this.throughputTokS,
  });

  /// Nodes currently online. The headline count.
  final int onlineNodes;

  /// Models the grid advertises. Read from [gridModelsProvider] rather than
  /// `stats.models`, which the relay sometimes reports as 0 even when the model
  /// list is populated.
  final int models;

  /// Total GPU memory across online nodes, in GB. Null when no online node
  /// reports any — CPU-only grids, or providers that don't advertise VRAM.
  /// Never 0: absent and "zero GB" are different claims, and only one of them is
  /// honest here.
  final double? vramGb;

  /// How many requests the grid can serve concurrently — the relay's own
  /// `stats.concurrent_capacity` when it reports one, otherwise the sum of each
  /// online node's `max_concurrency`. Null when neither is available.
  final int? parallel;

  /// Combined tokens/second across online nodes. Null when no node reports it.
  final double? throughputTokS;

  /// Whether there is anything worth showing. The pill unmounts on false rather
  /// than rendering an empty capsule or a row of dashes.
  bool get isEmpty => onlineNodes == 0 && models == 0;

  /// Whether any hardware detail resolved — decides if the popover has a
  /// "power" block to show at all, or only the node list.
  bool get hasSpecs =>
      vramGb != null || parallel != null || throughputTokS != null;
}

/// GPU memory a node brings, in GB, or null when it reports none. Prefers the
/// relay's `vram_gb`, falling back to `vram_total_mb ÷ 1024`.
///
/// Mirrors the same preference order as `nodeVramLabel`, which formats this for
/// a single node's spec line. Kept separate because that one returns a display
/// string ("64 GB VRAM") and this one has to stay summable.
double? nodeVramGb(OverviewNode node) {
  final gb =
      node.vramGb ??
      (node.vramTotalMb == null ? null : node.vramTotalMb! / 1024);
  if (gb == null || gb <= 0) return null;
  return gb;
}

/// Derives [GridPower] from a set of nodes and a model count. Pure, so the
/// summing rules — online-only, null-preserving — are unit-testable without a
/// relay.
///
/// Each hardware total stays null unless at least one online node reported that
/// field: a grid where nobody advertises throughput shows no throughput row,
/// rather than claiming "0 tok/s".
///
/// [capacity] is the relay's own `stats.concurrent_capacity`. When present it
/// wins over summing each node's `max_concurrency`: the relay is the authority
/// on how much work it will actually dispatch, and it may cap or oversubscribe
/// what the nodes individually advertise. Summing is the fallback for a relay
/// that doesn't report it.
GridPower gridPowerFrom(
  Iterable<OverviewNode> nodes,
  int models, {
  int? capacity,
}) {
  final online = [
    for (final n in nodes)
      if (n.online) n,
  ];

  double? vram;
  int? summedConcurrency;
  double? throughput;
  for (final node in online) {
    final gb = nodeVramGb(node);
    if (gb != null) vram = (vram ?? 0) + gb;

    final concurrency = node.maxConcurrency;
    if (concurrency != null && concurrency > 0) {
      summedConcurrency = (summedConcurrency ?? 0) + concurrency;
    }

    final toks = node.throughputTokS;
    if (toks != null && toks > 0) throughput = (throughput ?? 0) + toks;
  }

  return GridPower(
    onlineNodes: online.length,
    models: models,
    vramGb: vram,
    parallel: (capacity != null && capacity > 0) ? capacity : summedConcurrency,
    throughputTokS: throughput,
  );
}

/// The selected grid's power summary. Empty (and the pill unmounted) while the
/// overview loads, when it fails, or when no grid is selected — the top bar
/// stays quiet rather than flashing a skeleton on every grid switch.
final gridPowerProvider = Provider.autoDispose<GridPower>((ref) {
  final grid = ref.watch(selectedNetworkProvider);
  if (grid == null) {
    return const GridPower(onlineNodes: 0, models: 0);
  }
  final overview = ref
      .watch(gridOverviewForProvider(grid.networkId))
      .asData
      ?.value;
  return gridPowerFrom(
    overview?.nodes ?? const <OverviewNode>[],
    ref.watch(gridModelsProvider).length,
    capacity: overview?.stats.concurrentCapacity,
  );
});

/// The online nodes behind the selected grid, strongest first — the popover's
/// per-machine breakdown.
///
/// Sorted by GPU memory rather than left in relay order: the machine carrying
/// most of the grid is the one worth seeing first, and relay order buried a
/// 382 GB box under a 32 GB laptop. Nodes reporting no VRAM sort last, by name,
/// so the ordering stays stable between refreshes instead of shuffling.
final gridOnlineNodesProvider = Provider.autoDispose<List<OverviewNode>>((ref) {
  final grid = ref.watch(selectedNetworkProvider);
  if (grid == null) return const [];
  final nodes =
      ref.watch(gridOverviewForProvider(grid.networkId)).asData?.value.nodes ??
      const <OverviewNode>[];
  return sortNodesByPower([
    for (final n in nodes)
      if (n.online) n,
  ]);
});

/// Orders nodes by GPU memory, descending. Pure, and stable: ties and
/// VRAM-less nodes fall back to name order so the list doesn't reorder itself
/// on every poll.
List<OverviewNode> sortNodesByPower(List<OverviewNode> nodes) {
  final sorted = [...nodes];
  sorted.sort((a, b) {
    final av = nodeVramGb(a);
    final bv = nodeVramGb(b);
    if (av == null && bv == null) return a.name.compareTo(b.name);
    if (av == null) return 1;
    if (bv == null) return -1;
    final byVram = bv.compareTo(av);
    return byVram != 0 ? byVram : a.name.compareTo(b.name);
  });
  return sorted;
}

/// Strips the leading segment a name shares with at least one *other* name, so
/// what distinguishes two machines is what the eye lands on.
///
/// `MacBooks-MacBook-Pro-6` beside `MacBooks-MacBook-Pro-6.local` reads as a
/// display bug; dropping the shared `MacBooks-` leaves the real difference
/// visible.
///
/// Trimming is per *group*, not across the whole list. A real grid mixes
/// machines — `engine-b0dc5f98` alongside two MacBooks — and an earlier version
/// required every name to share the prefix, so one odd machine out disabled the
/// trim for all of them. Here each name is trimmed if and only if its own first
/// segment is repeated somewhere else in the list; a machine standing alone
/// keeps its full name.
///
/// Only the first segment goes, never the whole common prefix: when one name is
/// a prefix of another, the full common run reaches deep into the name and those
/// two would collapse to `6.local` and `6` — worse than the repetition it set
/// out to fix.
List<String> shortenNodeNames(List<String> names) {
  if (names.length < 2) return names;

  // Group by first segment, so we only trim what's actually repeated.
  final counts = <String, int>{};
  for (final name in names) {
    final segment = _firstSegment(name);
    if (segment != null) counts[segment] = (counts[segment] ?? 0) + 1;
  }

  return [
    for (final name in names)
      if (_firstSegment(name) case final segment?
          when (counts[segment] ?? 0) > 1 && name.length > segment.length)
        name.substring(segment.length)
      else
        name,
  ];
}

/// The leading `prefix-` of a name, separator included, or null when the name
/// has no separator or nothing would be left after the cut.
String? _firstSegment(String name) {
  for (var i = 0; i < name.length; i++) {
    if (_isSeparator(name[i])) {
      final cut = i + 1;
      return cut < name.length ? name.substring(0, cut) : null;
    }
  }
  return null;
}

bool _isSeparator(String c) => c == '-' || c == '_' || c == '.' || c == ' ';

/// Pluralises a unit against its count: `1 node`, `3 nodes`. Every count in the
/// pill and panel goes through this — a grid with one machine must never read
/// "1 nodes".
String plural(int count, String singular, [String? plural]) =>
    count == 1 ? singular : (plural ?? '${singular}s');

/// Formats a GB figure for display: drops a trailing `.0` (`64.0 → "64"`), keeps
/// one decimal otherwise (`446.4`), and switches to TB past 1024 so a large grid
/// reads as "1.2 TB" instead of a four-digit GB number that no longer scans.
String formatVram(double gb) {
  if (gb >= 1024) {
    final tb = gb / 1024;
    return '${_trim(tb)} TB';
  }
  return '${_trim(gb)} GB';
}

/// Formats throughput as a rounded rate — the underlying figure is an estimate,
/// so decimals would imply precision the relay doesn't have.
String formatThroughput(double tokS) => '~${tokS.round()}';

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
