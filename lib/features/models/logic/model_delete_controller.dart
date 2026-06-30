import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import 'models_providers.dart';

final modelDeleteControllerProvider =
    NotifierProvider<ModelDeleteController, ModelDeleteState>(
        ModelDeleteController.new);

sealed class ModelDeleteState {
  const ModelDeleteState();
}

class ModelDeleteIdle extends ModelDeleteState {
  const ModelDeleteIdle();
}

/// A delete is in flight for [name] (used to show a spinner on that row).
class ModelDeleting extends ModelDeleteState {
  const ModelDeleting(this.name);
  final String name;
}

class ModelDeleteFailed extends ModelDeleteState {
  const ModelDeleteFailed({required this.name, required this.message});
  final String name;
  final String message;
}

/// Removes a downloaded model via `grid rm <name>`, then rescans
/// `~/.grid/models`. This is the only mutation path — the store reads, the CLI
/// deletes the file. Callers must first ensure the model isn't being served (see
/// [servingModelProvider] / [isModelInUse]); this controller doesn't re-check, so
/// the guard stays in one place at the UI boundary.
class ModelDeleteController extends Notifier<ModelDeleteState> {
  @override
  ModelDeleteState build() => const ModelDeleteIdle();

  /// Returns true on success. On failure, [state] holds a [ModelDeleteFailed]
  /// with a user-friendly message (raw CLI detail still lands in the Debug log).
  Future<bool> delete(String name) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = ModelDeleteFailed(
          name: name,
          message: "Grid's background helper isn't available — please restart "
              'the app.');
      return false;
    }

    state = ModelDeleting(name);
    // TODO(BE): assumes the merged CLI removes a stored model with
    // `grid rm <file>` (the mode-agnostic `rm` command, parallel to `pull`).
    // Revisit the arg form if the CLI expects something else.
    final result = await service.run(['rm', name]);
    if (!result.ok) {
      state = ModelDeleteFailed(
          name: name, message: "Couldn't delete this model. Please try again.");
      return false;
    }

    ref.invalidate(localModelsProvider);
    state = const ModelDeleteIdle();
    return true;
  }
}

/// True when [modelName] (a local gguf filename) matches what the running engine
/// is serving. Exact for an in-session built-in serve (we pass the gguf name as
/// `--serve`); a lenient substring match otherwise, so an engine adopted on
/// restart — whose record stores the advertised name, a prefix of the filename —
/// still counts. Biased toward "in use" so we never delete a model that's live.
bool isModelInUse(String modelName, String? servingModel) {
  if (servingModel == null || servingModel.trim().isEmpty) return false;
  final name = modelName.toLowerCase();
  for (final part in servingModel.split(',')) {
    final m = part.trim().toLowerCase();
    if (m.isEmpty) continue;
    if (name == m || name.contains(m) || m.contains(name)) return true;
  }
  return false;
}
