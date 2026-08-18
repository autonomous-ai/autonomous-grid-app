import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import 'models_providers.dart';

final modelDeleteControllerProvider =
    NotifierProvider<ModelDeleteController, ModelDeleteState>(
      ModelDeleteController.new,
    );

sealed class ModelDeleteState {
  const ModelDeleteState();
}

class ModelDeleteIdle extends ModelDeleteState {
  const ModelDeleteIdle();
}

/// A delete is in flight for the model shown as [label] (used to spin its row).
class ModelDeleting extends ModelDeleteState {
  const ModelDeleting(this.label);
  final String label;
}

class ModelDeleteFailed extends ModelDeleteState {
  const ModelDeleteFailed({required this.label, required this.message});
  final String label;
  final String message;
}

/// Removes a downloaded model via `grid rm <file>`, then rescans
/// `~/.grid/models`. A split model is several files, so [delete] takes every
/// file backing one model and removes them together — as does the wreck of a
/// download that stopped partway, whose `.part` `grid rm` deletes like any
/// other file under the models folder. This is the only mutation path — the
/// store reads, the CLI deletes the files. Callers must first ensure the model
/// isn't being served (see [servingModelProvider] / [isModelInUse]); this
/// controller doesn't re-check, so the guard stays in one place at the UI
/// boundary.
class ModelDeleteController extends Notifier<ModelDeleteState> {
  @override
  ModelDeleteState build() => const ModelDeleteIdle();

  /// Removes every file in [files], shown to the user as [label]. Returns true
  /// on success. On failure, [state] holds a [ModelDeleteFailed] with a
  /// user-friendly message (raw CLI detail still lands in the Debug log).
  Future<bool> delete(List<String> files, {required String label}) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = ModelDeleteFailed(
        label: label,
        message:
            "Grid's background helper isn't available — please restart "
            'the app.',
      );
      return false;
    }

    state = ModelDeleting(label);
    // `grid rm <file>` deletes a stored model by its filename under
    // ~/.grid/models. `--yes` is REQUIRED: without it the CLI calls input() for
    // a [y/N] confirmation, which EOFs on our non-interactive stdin and aborts
    // (exit 1) — the app can't answer a prompt.
    for (final file in files) {
      final result = await service.run(['rm', file, '--yes']);
      if (!result.ok) {
        // Rescan so the list reflects whatever was already removed.
        _rescan();
        state = ModelDeleteFailed(
          label: label,
          message: "Couldn't delete this model. Please try again.",
        );
        return false;
      }
    }

    _rescan();
    state = const ModelDeleteIdle();
    return true;
  }

  /// Drops a failure the user has already read, so reopening the list doesn't
  /// greet them with an error about something that is no longer happening.
  /// Only clears [ModelDeleteFailed]: idle and deleting both describe something
  /// real that a dismissal must not overwrite.
  void clearFailure() {
    if (state is ModelDeleteFailed) state = const ModelDeleteIdle();
  }

  /// Re-reads the models folder. Both lists, because a delete may have removed
  /// a finished `.gguf` or the `.part` of one that never finished.
  void _rescan() {
    ref.invalidate(localModelsProvider);
    ref.invalidate(downloadingModelsProvider);
  }
}
