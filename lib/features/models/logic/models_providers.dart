import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../infrastructure/cli/parsers/model_context.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/local_files.dart';
import 'model_group.dart';
import 'model_storage.dart';

/// GGUF models found under `~/.grid/models/`. Invalidate to rescan.
final localModelsProvider = Provider<List<LocalModel>>((ref) {
  return ref.watch(gridHomeStoreProvider).listLocalModels();
});

/// Models still downloading — a `<name>.gguf.part` the CLI hasn't finished and
/// renamed to `.gguf` yet. Lets the UI tell "a model is on its way" apart from
/// "no model", and lets the auto-download stand down instead of starting a
/// second pull over a part-file. Invalidate alongside [localModelsProvider] to
/// rescan (a `.part` becomes a `.gguf` the moment it completes).
final downloadingModelsProvider = Provider<List<DownloadingModel>>((ref) {
  return ref.watch(gridHomeStoreProvider).listDownloadingModels();
});

/// The same models, grouped so a split GGUF's parts read as one servable model.
/// The model list, the serve picker and delete all work off this so they stay
/// consistent — one model, one row, one action.
final modelGroupsProvider = Provider<List<ModelGroup>>((ref) {
  return groupLocalModels(ref.watch(localModelsProvider));
});

/// Everything taking up space under `~/.grid/models`, biggest first — finished
/// models and the leftovers of downloads that stopped, which the storage list
/// deletes through the same path. Rebuilds whenever either scan is invalidated.
final storedItemsProvider = Provider<List<StoredItem>>((ref) {
  return storedItems(
    groups: ref.watch(modelGroupsProvider),
    partials: ref.watch(downloadingModelsProvider),
  );
});

/// Maximum context length (tokens) the given local model supports, read from
/// `grid ctx --json <model>`. Keyed by the GGUF filename (as listed by
/// [localModelsProvider]). Null when the CLI is unavailable or the model's
/// context can't be read — callers then fall back to the engine's own default.
final modelMaxContextProvider = FutureProvider.family<int?, String>((
  ref,
  model,
) async {
  final service = ref.watch(gridCliServiceProvider);
  if (service == null) return null;
  final result = await service.run(['ctx', '--json', model]);
  if (!result.ok) return null;
  return ModelContext.parse(result.stdout)?.contextLength;
});

/// Curated models the CLI can pull, from `grid catalog`'s "Grid can pull:"
/// block — each tagged with the device it targets (Apple Silicon / NVIDIA) and
/// its minimum GPU memory. Lets the model manager offer one-tap downloads
/// instead of making the user type a `repo:file` spec. Empty on any failure, so
/// the suggested-models section simply hides.
final catalogModelsProvider = FutureProvider<List<CatalogEntry>>((ref) async {
  final service = ref.watch(gridCliServiceProvider);
  if (service == null) return const [];
  final result = await service.run(const ['catalog']);
  if (!result.ok) return const [];
  return CatalogEntry.parseAll(result.stdout);
});
