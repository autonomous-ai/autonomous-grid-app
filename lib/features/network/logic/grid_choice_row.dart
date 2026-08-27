import '../../../shared/copy/plural.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import 'grid_access_summary.dart';

/// What one grid's row says about itself under its name.
///
/// The design puts a live sentence there — how many computers are answering,
/// and what the grid holds — which is the difference between choosing a grid
/// and guessing at one. Everything it can say comes from that grid's own
/// overview, probed per grid; nothing is inferred, and the two states where
/// there is no answer yet say so rather than reporting zero.
sealed class GridLiveness {
  const GridLiveness();
}

/// The probe is still out. Distinct from "nothing is answering", which is what
/// a zero here would be read as — and would be wrong for the second or two it
/// takes every grid on the account to reply.
class GridChecking extends GridLiveness {
  const GridChecking();
}

/// The grid did not answer. Says so rather than reporting an empty grid: a
/// control plane that is down is not a grid with nobody on it, and the reader
/// picking between them needs to know which they are looking at.
class GridUnreachable extends GridLiveness {
  const GridUnreachable();
}

/// The grid answered.
class GridReached extends GridLiveness {
  const GridReached({
    required this.running,
    required this.nodes,
    required this.models,
  });

  /// Whether the grid itself reports as up — the same field the Grids list
  /// colours its bolt from.
  final bool running;

  final int nodes;
  final int models;
}

/// Whether anything is actually answering on this grid.
///
/// The count, not the state. A grid can report `running` with nothing on it —
/// two on this account do — and reading the state alone put a green dot beside
/// a grid that could not answer a single question. The dot and the sentence
/// below it both come through here now, so they cannot say different things
/// about the same grid.
bool gridIsAnswering(GridLiveness liveness) => switch (liveness) {
  GridReached(:final running, :final nodes) => running && nodes > 0,
  _ => false,
};

/// The sentence under a grid's name.
///
/// Pure, because this is the line that goes stale silently: it is assembled
/// from three numbers and a state, and every one of them has a "we don't know
/// yet" that reads as a fact if it is allowed to fall through to zero.
String gridRowMeta(GridLiveness liveness) {
  if (liveness is GridChecking) return 'Checking…';
  if (liveness is GridUnreachable) return "Can't reach this grid right now";
  if (!gridIsAnswering(liveness)) return 'No computers answering';
  final reached = liveness as GridReached;
  final computers =
      '${reached.nodes} ${plural(reached.nodes, 'computer')} answering';
  if (reached.models == 0) return computers;
  return '$computers · ${reached.models} '
      '${plural(reached.models, 'model')}';
}

/// The grids on this account, in the order and groups the list draws them.
///
/// Empty groups are left out entirely rather than drawn as a heading over
/// nothing — on most accounts two of the three are empty.
List<({GridAccessTag tag, List<NetworkCredential> grids})> groupGrids(
  List<NetworkCredential> networks,
) => [
  for (final tag in kGridGroupOrder)
    if (networks.where((n) => gridAccessTagFor(n) == tag).toList()
        case final grids when grids.isNotEmpty)
      (tag: tag, grids: grids),
];

/// The grids whose name contains [query], case- and space-insensitively.
///
/// A blank query is not a filter — it returns everything rather than nothing,
/// which is the bug this shape exists to make impossible.
List<NetworkCredential> filterGrids(
  List<NetworkCredential> networks,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return networks;
  return [
    for (final network in networks)
      if (network.name.toLowerCase().contains(needle)) network,
  ];
}

/// The count beside the search box: "12 grids", or "3 of 12" while filtering.
String gridCountLabel({required int shown, required int total}) =>
    shown == total ? '$total ${plural(total, 'grid')}' : '$shown of $total';
