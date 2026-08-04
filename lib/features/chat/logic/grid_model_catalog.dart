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
      nodesOf(ref.watch(gridOverviewForProvider(grid.networkId))),
    ),
  ];
});

/// The nodes a grid's overview reports, or none while it's still loading /
/// offline — what they add (the Image/Video modes, and which engine is behind
/// each model) is a bonus on top of the `/models` list, never a reason to block
/// or fail the group.
List<OverviewNode> nodesOf(AsyncValue<GridOverview> overview) =>
    overview.value?.nodes ?? const <OverviewNode>[];

/// Re-reads what the selected grid serves, in the background.
///
/// Nothing else does. The list is fetched once when the app opens and then held
/// for as long as the composer is mounted — the model pill watches
/// [gridModelCatalogProvider], so the `/models` call never auto-disposes and
/// never runs again. A teammate who starts serving a model an hour in doesn't
/// appear, and one who stopped is still offered — the overview beside it polls,
/// but it only supplies the media modes, never the model rows.
///
/// Opening the picker is the moment the user asks "what can I pick?", so that's
/// when it's re-read. Silent by design: the models already listed stay up while
/// the call is in flight (see [gridModelGroupFrom]), so the menu opens on the
/// list it knew and swaps when the answer lands, rather than on a skeleton.
void refreshGridModelCatalog(WidgetRef ref) {
  final grid = ref.read(selectedNetworkProvider);
  if (grid == null) return;
  ref.invalidate(networkModelsForProvider(grid.networkId));
}

/// Maps a grid's served-model list plus its [nodes] into a menu group. The
/// list's [models] async drives the loading / ready / offline state; the nodes
/// add the Image/Video modes and say where each model actually runs. Pure so the
/// mapping is unit-tested without any async or provider timing.
GridModelGroup gridModelGroupFrom(
  NetworkCredential grid,
  AsyncValue<List<String>> models,
  List<OverviewNode> nodes,
) => models.when(
  // A refresh keeps the models it already had. Only a grid with nothing cached
  // reads as loading — every open would otherwise blink the menu (and the pill
  // beside it) to a skeleton for the length of a round trip, which is a worse
  // trade than showing one model a second late.
  skipLoadingOnReload: true,
  data: (ids) => GridModelGroup(
    grid: grid,
    options: playgroundOptionsFrom(
      [for (final id in ids) OverviewModel(id: id)],
      [for (final node in nodes) ...node.models],
      hosting: hostingByModel(nodes),
    ),
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
