import '../../../infrastructure/state/models/network_credential.dart';

/// The grids the engines page can switch to, split by the one thing that page
/// is about: whether a model can actually be shared on them.
///
/// Grouping by *ownership* would be the obvious read of "mine / the rest", but
/// it is the wrong axis here — sharing is gated on the `provider:poll` scope
/// ([NetworkCredential.isProvider]), not on the admin role, and the two come
/// apart: a grid someone else owns can grant you sharing rights, and it belongs
/// beside the others you can serve on.
class GridChoices {
  const GridChoices({required this.canShare, required this.viewOnly});

  /// Grids this account may run an engine on.
  final List<NetworkCredential> canShare;

  /// Grids it may only consume from — switching to one is a real move, just a
  /// lesser one on a page about sharing.
  final List<NetworkCredential> viewOnly;

  /// Nothing to switch to: a single-grid account.
  bool get isEmpty => canShare.isEmpty && viewOnly.isEmpty;

  /// Whether both groups have members — the only case where a heading tells
  /// them apart rather than repeating what the one group already is.
  bool get isSplit => canShare.isNotEmpty && viewOnly.isNotEmpty;
}

/// Every grid in [grids] except [current], grouped for the switcher.
///
/// Order inside a group is left exactly as the credentials file has it, so the
/// chips don't reshuffle under the cursor when something else re-reads the file.
GridChoices buildGridChoices(
  List<NetworkCredential> grids,
  NetworkCredential current,
) {
  final others = [
    for (final grid in grids)
      if (grid.networkId != current.networkId) grid,
  ];
  return GridChoices(
    canShare: List.unmodifiable([
      for (final grid in others)
        if (grid.isProvider) grid,
    ]),
    viewOnly: List.unmodifiable([
      for (final grid in others)
        if (!grid.isProvider) grid,
    ]),
  );
}
