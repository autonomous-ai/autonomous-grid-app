import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
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

/// The selected grid's model options for the unified picker.
///
/// Scoped to the active grid ([selectedNetworkProvider]): the picker shows only
/// the grid you're on, so other grids' models stay hidden — and aren't probed.
/// The chat model list is the relay's OpenAI-style `/models`
/// ([networkModelsForProvider]) — the canonical list of what a grid can serve,
/// already stripped of a lone `auto` router, so a grid with nothing behind the
/// router shows "no model yet" instead of a model that can't answer. The
/// overview is still read, but only for the node
/// comfyui capabilities that power the Image/Video modes (those never appear in
/// `/models`); it's best-effort, so the chat models never wait on it. Empty when
/// no grid is selected.
final gridModelCatalogProvider = Provider.autoDispose<List<GridModelGroup>>((
  ref,
) {
  final grid = ref.watch(selectedNetworkProvider);
  if (grid == null) return const [];
  return [
    gridModelGroupFrom(
      grid,
      ref.watch(networkModelsForProvider(grid.networkId)),
      mediaCapabilitiesOf(ref.watch(gridOverviewForProvider(grid.networkId))),
    ),
  ];
});

/// The comfyui capabilities a grid's overview advertises across its nodes, or
/// none while it's still loading / offline — media modes are a bonus on top of
/// the `/models` list, never a reason to block or fail the group.
List<String> mediaCapabilitiesOf(AsyncValue<GridOverview> overview) => [
  for (final node in overview.asData?.value.nodes ?? const <OverviewNode>[])
    ...node.models,
];

/// Maps a grid's served-model list plus its media [capabilities] into a menu
/// group. The list's [models] async drives the loading / ready / offline state;
/// capabilities only add the Image/Video modes. Pure so the mapping is
/// unit-tested without any async or provider timing.
GridModelGroup gridModelGroupFrom(
  NetworkCredential grid,
  AsyncValue<List<String>> models,
  List<String> capabilities,
) => models.when(
  skipLoadingOnReload: false,
  data: (ids) => GridModelGroup(
    grid: grid,
    options: playgroundOptionsFrom([
      for (final id in ids) OverviewModel(id: id),
    ], capabilities),
    status: GridModelStatus.ready,
  ),
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
