import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/providers.dart';
import 'models_providers.dart';

final modelPullControllerProvider =
    NotifierProvider<ModelPullController, ModelPullState>(
        ModelPullController.new);

sealed class ModelPullState {
  const ModelPullState();
}

class ModelPullIdle extends ModelPullState {
  const ModelPullIdle();
}

/// Download in progress. [progress] is null until the first parsable bar
/// arrives (callers show an indeterminate spinner meanwhile).
class ModelPulling extends ModelPullState {
  const ModelPulling({required this.spec, this.progress});
  final String spec;
  final DownloadProgress? progress;
}

class ModelPullDone extends ModelPullState {
  const ModelPullDone(this.file);
  final String file;
}

class ModelPullFailed extends ModelPullState {
  const ModelPullFailed(this.message);
  final String message;
}

/// Runs `grid models pull <repo>:<file>`, streaming the stderr download bar
/// (§3.4). `pull()` doesn't surface an exit code, so success is confirmed by
/// re-scanning `~/.grid/models` for the target file afterwards.
class ModelPullController extends Notifier<ModelPullState> {
  @override
  ModelPullState build() => const ModelPullIdle();

  Future<void> pull(String spec) async {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ModelPullFailed('grid executable not found.');
      return;
    }

    state = ModelPulling(spec: trimmed);
    try {
      await for (final progress in service.pull(['models', 'pull', trimmed])) {
        state = ModelPulling(spec: trimmed, progress: progress);
      }
    } catch (error) {
      state = ModelPullFailed(error.toString());
      return;
    }

    // Refresh the on-disk list and confirm the file actually landed.
    ref.invalidate(localModelsProvider);
    final target = trimmed.contains(':') ? trimmed.split(':').last : null;
    final models = ref.read(localModelsProvider);
    if (target == null || models.any((m) => m.name == target)) {
      state = ModelPullDone(target ?? trimmed);
    } else {
      state = ModelPullFailed(
        'Download finished but "$target" is not in ~/.grid/models — '
        'check the repo:file spec.',
      );
    }
  }

  void reset() => state = const ModelPullIdle();
}
