import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/local_files.dart';

/// GGUF models found under `~/.grid/models/`. Invalidate to rescan.
final localModelsProvider = Provider<List<LocalModel>>((ref) {
  return ref.watch(gridHomeStoreProvider).listLocalModels();
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
