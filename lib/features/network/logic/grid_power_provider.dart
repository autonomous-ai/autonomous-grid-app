import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../auth/logic/session_controller.dart';
import 'grid_overview_provider.dart';
import 'node_display.dart';

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
    this.vramUsedGb,
    this.gpuUtilPct,
    this.parallel,
    this.throughputTokS,
    this.answered,
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

  /// GPU memory currently in use across the same online nodes [vramGb] sums, in
  /// GB. Null when no node reports it — a pool total on its own says what the
  /// grid *has*, this is the half that says how much of it is already spoken
  /// for, and the ring in the top bar draws the two against each other.
  ///
  /// Summed under the same rule as [vramGb], subscription seats excluded: a
  /// used figure counted over a different set of machines than the total would
  /// produce a ratio that is quietly wrong rather than obviously missing.
  final double? vramUsedGb;

  /// Mean GPU utilisation across the online nodes that report it, 0–100. Null
  /// when none does.
  ///
  /// The fallback the memory ring falls back *to*: a relay that sends no
  /// `vram_used_mb` can still say how hard the cards are working, and a ring
  /// with nothing to draw is a hole in the capsule.
  final double? gpuUtilPct;

  /// How many requests the grid can serve concurrently — the relay's own
  /// `stats.concurrent_capacity` when it reports one, otherwise the sum of each
  /// online node's `max_concurrency`. Null when neither is available.
  final int? parallel;

  /// Combined tokens/second across online nodes. Null when no node reports it.
  final double? throughputTokS;

  /// What the whole grid has answered inside the relay's window, summed over its
  /// online nodes. Null when **no** node reported the rollup — an older relay —
  /// and the pill then shows no such figure rather than a zero.
  ///
  /// Unlike [throughputTokS] this is a total of totals, so its own `byModel` is
  /// left empty: the per-model split of a grid comes from [answeredByModel],
  /// which keys by model across nodes rather than summing whole nodes.
  final NodeAnswered? answered;

  /// Whether there is anything worth showing. The pill unmounts on false rather
  /// than rendering an empty capsule or a row of dashes.
  bool get isEmpty => onlineNodes == 0 && models == 0;

  /// Whether any hardware detail resolved — decides if the popover has a
  /// "power" block to show at all, or only the node list.
  bool get hasSpecs =>
      vramGb != null || parallel != null || throughputTokS != null;

  /// Value equality so a poll that changed nothing produces no pill rebuild.
  /// [gridPowerProvider] recomputes on every overview notification — including
  /// the background refresh that keeps the last value on screen — and without
  /// this each identical result is a fresh instance the provider treats as a
  /// change, rebuilding the top bar for no visible reason.
  @override
  bool operator ==(Object other) =>
      other is GridPower &&
      other.onlineNodes == onlineNodes &&
      other.models == models &&
      other.vramGb == vramGb &&
      other.vramUsedGb == vramUsedGb &&
      other.gpuUtilPct == gpuUtilPct &&
      other.parallel == parallel &&
      other.throughputTokS == throughputTokS &&
      other.answered == answered;

  @override
  int get hashCode => Object.hash(
    onlineNodes,
    models,
    vramGb,
    vramUsedGb,
    gpuUtilPct,
    parallel,
    throughputTokS,
    answered,
  );
}

/// GPU memory a node contributes to the grid pool, in GB, or null when it brings
/// none. Prefers the relay's `vram_gb`, falling back to `vram_total_mb ÷ 1024`.
///
/// A subscription seat (codex/ChatGPT) returns null however much memory its
/// machine reports: it relays to a hosted model, so that RAM never runs a model
/// for the grid, and counting it would inflate the graphics-memory pool with
/// capacity no one on the grid can use — it brings a plan, shown as such, not
/// GPU memory (see [nodeIsSubscription]).
///
/// Mirrors the same preference order as `nodeVramLabel`, which formats a single
/// machine's own spec line — that one still shows the machine's RAM, because a
/// subscription box does have it; this one answers what the *pool* gets.
double? nodeVramGb(OverviewNode node) {
  if (nodeIsSubscription(node)) return null;
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
/// [gridAnswered] is the relay's own grid-wide rollup. When present it wins over
/// summing the nodes, and the difference is not cosmetic: a node is listed only
/// while its heartbeat is live, so a machine that served all morning and then
/// went offline takes its tokens out of a summed total — and the relay's node
/// rollup separately drops rows it cannot attribute to a machine. Summing
/// therefore reports a figure that is quietly low, and low by an amount that
/// moves as machines come and go. Two surfaces reading the same grid then showed
/// two different token counts with no way to tell which was wrong.
///
/// Null on a relay that predates the field, or one whose first rollup hasn't
/// landed — the node sum is the fallback there. Worse, but the only thing such a
/// grid can offer, and still better than showing nothing.
GridPower gridPowerFrom(
  Iterable<OverviewNode> nodes,
  int models, {
  int? capacity,
  NodeAnswered? gridAnswered,
}) {
  final online = [
    for (final n in nodes)
      if (n.online) n,
  ];

  double? vram;
  double? vramUsed;
  var gpuUtilSum = 0.0;
  var gpuUtilNodes = 0;
  int? summedConcurrency;
  double? throughput;
  // Null until some node actually reports a rollup, so a grid of older relays
  // shows no figure at all. Zeros here would be indistinguishable from a real
  // measurement of an idle grid, which is the one thing this must not do.
  int? answeredOut;
  int answeredIn = 0;
  int answeredCached = 0;
  int answeredRequests = 0;
  int answeredWindow = 0;
  for (final node in online) {
    final gb = nodeVramGb(node);
    if (gb != null) vram = (vram ?? 0) + gb;

    // Both live figures follow the pool's own membership rule: whatever
    // `nodeVramGb` refused (a subscription seat, a machine advertising no
    // memory) contributes neither a used share nor a utilisation reading, so
    // the ratio drawn in the bar is over one consistent set of machines.
    if (gb != null) {
      final usedMb = node.vramUsedMb;
      if (usedMb != null && usedMb > 0) {
        vramUsed = (vramUsed ?? 0) + usedMb / 1024;
      }
      final util = node.gpuUtilPct;
      if (util != null && util >= 0) {
        gpuUtilSum += util;
        gpuUtilNodes++;
      }
    }

    final concurrency = node.maxConcurrency;
    if (concurrency != null && concurrency > 0) {
      summedConcurrency = (summedConcurrency ?? 0) + concurrency;
    }

    final toks = node.throughputTokS;
    if (toks != null && toks > 0) throughput = (throughput ?? 0) + toks;

    final answered = node.answered;
    if (answered != null) {
      answeredOut = (answeredOut ?? 0) + answered.tokensOut;
      answeredIn += answered.tokensIn;
      answeredCached += answered.tokensCached;
      answeredRequests += answered.requests;
      // One window setting on one relay, so every node agrees; the first one
      // seen is the one reported.
      if (answeredWindow == 0) answeredWindow = answered.windowSeconds;
    }
  }

  return GridPower(
    onlineNodes: online.length,
    models: models,
    vramGb: vram,
    // Never above the pool it is a share of: a node reporting more used than it
    // advertises as total (a driver rounding, a seat counted twice) would draw a
    // ring past full, which reads as a bug rather than as load.
    vramUsedGb: vram == null || vramUsed == null
        ? null
        : (vramUsed > vram ? vram : vramUsed),
    gpuUtilPct: gpuUtilNodes == 0 ? null : gpuUtilSum / gpuUtilNodes,
    parallel: (capacity != null && capacity > 0) ? capacity : summedConcurrency,
    throughputTokS: throughput,
    // The grid's own rollup first — see the note on [gridAnswered]. The node sum
    // is only what a relay too old to send one leaves us.
    answered:
        gridAnswered ??
        (answeredOut == null
            ? null
            : NodeAnswered(
                windowSeconds: answeredWindow,
                tokensIn: answeredIn,
                tokensCached: answeredCached,
                tokensOut: answeredOut,
                requests: answeredRequests,
              )),
  );
}

/// The selected grid's power summary. Empty (and the pill unmounted) while the
/// overview loads, when it fails, or when no grid is selected — the top bar
/// stays quiet rather than flashing a skeleton on every grid switch.
///
/// Reads the overview through [gridOverviewSnapshot], the same door
/// [gridModelsProvider] uses, and **not** through `gridOverviewForProvider`
/// directly. Watching both doors in one body reached the same cache twice: the
/// direct watch flushed the family member, which dirtied the alias, which then
/// flushed on the *second* watch and notified its other listeners — inside a
/// widget's build, since that is where this provider first mounts. One of those
/// listeners invalidating itself there is `setState() called during build`.
final gridPowerProvider = Provider.autoDispose<GridPower>((ref) {
  if (ref.watch(selectedNetworkProvider) == null) {
    return const GridPower(onlineNodes: 0, models: 0);
  }
  final overview = ref.watch(gridOverviewSnapshot);
  return gridPowerFrom(
    overview?.nodes ?? const <OverviewNode>[],
    ref.watch(gridModelsProvider).length,
    capacity: overview?.stats.concurrentCapacity,
    gridAnswered: overview?.answered,
  );
});

/// The online nodes behind the selected grid, strongest first — the popover's
/// per-machine breakdown.
///
/// Sorted by GPU memory rather than left in relay order: the machine carrying
/// most of the grid is the one worth seeing first, and relay order buried a
/// 382 GB box under a 32 GB laptop. Nodes reporting no VRAM sort last, by name,
/// so the ordering stays stable between refreshes instead of shuffling.
/// Same one-door rule as [gridPowerProvider]: the popover and the pill mount
/// together, so a second path into the overview cache would reintroduce the
/// mid-build flush this pair was fixed for.
final gridOnlineNodesProvider = Provider.autoDispose<List<OverviewNode>>((ref) {
  if (ref.watch(selectedNetworkProvider) == null) return const [];
  final nodes =
      ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[];
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

/// GPU memory a node currently has in use, in GB, or null when it doesn't say.
///
/// Gated on [nodeVramGb] rather than read straight off the node: a machine that
/// brings no memory to the pool contributes no used share either, and a
/// subscription seat reporting its host's RAM would otherwise appear to be
/// consuming grid memory it never had.
double? nodeVramUsedGb(OverviewNode node) {
  if (nodeVramGb(node) == null) return null;
  final usedMb = node.vramUsedMb;
  if (usedMb == null || usedMb <= 0) return null;
  return usedMb / 1024;
}

/// "1.3 / 2.1 TB" — memory in use against the pool it is drawn from, sharing one
/// unit between them.
///
/// The unit is written once, at the end, and chosen from the *total*: a grid
/// with 2.1 TB in it whose used share happens to be under a terabyte still reads
/// in terabytes, because two figures either side of a slash are being compared,
/// and a comparison written in two different units is a puzzle.
String formatVramShare(double usedGb, double totalGb) {
  if (totalGb >= 1024) {
    return '${_trim(usedGb / 1024)} / ${_trim(totalGb / 1024)} TB';
  }
  // One rule for both halves, decided by the total: "97.3 / 192 GB" reads as two
  // figures measured to different precisions, which is a claim about the
  // machine rather than about the column they had to fit in.
  final decimals = totalGb < 100;
  return '${_trimShare(usedGb, decimals)} / ${_trimShare(totalGb, decimals)} GB';
}

/// A figure inside a share, where two of them and a unit have to fit one column.
///
/// Drops the decimal from three digits up: "276.9 / 382.4" spends ten characters
/// on a tenth of a gigabyte nobody is acting on, and those characters are what
/// the machine's name loses. Under 100 the decimal stays — on a 63.7 GB card it
/// is a twentieth of the total, not a rounding. Both halves follow whichever
/// rule the total falls under, never one each.
String _trimShare(double v, bool decimals) =>
    decimals ? _trim(v) : v.round().toString();

/// Formats throughput as a rounded rate — the underlying figure is an estimate,
/// so decimals would imply precision the relay doesn't have.
String formatThroughput(double tokS) => '~${tokS.round()}';

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
