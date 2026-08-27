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

  /// Whether the grid reports itself as answering — the same field the Grids
  /// list colours its bolt from, so the two can never disagree.
  final bool running;

  final int nodes;
  final int models;
}

/// The sentence under a grid's name.
///
/// Pure, because this is the line that goes stale silently: it is assembled
/// from three numbers and a state, and every one of them has a "we don't know
/// yet" that reads as a fact if it is allowed to fall through to zero.
String gridRowMeta(GridLiveness liveness) => switch (liveness) {
  GridChecking() => 'Checking…',
  GridUnreachable() => "Can't reach this grid right now",
  GridReached(running: false) => 'Nobody answering right now',
  GridReached(:final nodes) when nodes == 0 => 'Answering now',
  GridReached(:final nodes, :final models) when models == 0 =>
    '$nodes ${plural(nodes, 'computer')} answering',
  GridReached(:final nodes, :final models) =>
    '$nodes ${plural(nodes, 'computer')} answering · '
        '$models ${plural(models, 'model')}',
};

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
