import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../playground/logic/playground_models.dart';

/// Whether a grid's models are still loading, ready, or the grid is unreachable —
/// so the unified picker can show a live state per group instead of a blank.
enum GridModelStatus { loading, ready, offline }

/// One grid and the models it currently serves, for the Chat tab's unified
/// grid+model picker. Each group is a section (grid name = header) in the menu,
/// mirroring how the reference picker groups by provider.
class GridModelGroup {
  const GridModelGroup({
    required this.grid,
    required this.options,
    required this.status,
  });

  final NetworkCredential grid;
  final List<PlaygroundModelOption> options;
  final GridModelStatus status;
}

/// Every grid's model options, gathered by probing each grid's overview in
/// parallel via [gridOverviewForProvider]. Watching this keeps those overviews
/// warm while the picker is open; offline grids surface as an [GridModelStatus]
/// rather than an error, so the menu always renders.
final gridModelCatalogProvider = Provider.autoDispose<List<GridModelGroup>>((
  ref,
) {
  final grids = ref.watch(sessionProvider).networks;
  return [for (final grid in grids) _groupFor(ref, grid)];
});

GridModelGroup _groupFor(Ref ref, NetworkCredential grid) {
  final overview = ref.watch(gridOverviewForProvider(grid.networkId));
  return overview.when(
    data: (data) {
      final capabilities = [for (final node in data.nodes) ...node.models];
      return GridModelGroup(
        grid: grid,
        options: playgroundOptionsFrom(data.models, capabilities),
        status: GridModelStatus.ready,
      );
    },
    loading: () => GridModelGroup(
      grid: grid,
      options: const [],
      status: GridModelStatus.loading,
    ),
    error: (_, _) => GridModelGroup(
      grid: grid,
      options: const [],
      status: GridModelStatus.offline,
    ),
  );
}
