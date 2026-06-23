import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/local_files.dart';

/// GGUF models found under `~/.grid/models/`. Invalidate to rescan.
final localModelsProvider = Provider<List<LocalModel>>((ref) {
  return ref.watch(gridHomeStoreProvider).listLocalModels();
});
