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

/// Runs `grid pull <repo>:<file>`, streaming the stderr download bar (§3.4).
/// `pull()` doesn't surface an exit code, so success is confirmed by re-scanning
/// `~/.grid/models` for the target file afterwards.
class ModelPullController extends Notifier<ModelPullState> {
  @override
  ModelPullState build() => const ModelPullIdle();

  Future<void> pull(String spec) async {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const ModelPullFailed(
          "Grid's background helper isn't available — please restart the app.");
      return;
    }

    state = ModelPulling(spec: trimmed);
    try {
      await for (final progress in service.pull(['pull', trimmed])) {
        state = ModelPulling(spec: trimmed, progress: progress);
      }
    } catch (_) {
      state = const ModelPullFailed(
          "Couldn't download the model — check your internet connection and "
          'that the model name is correct, then try again.');
      return;
    }

    // Refresh the on-disk list and confirm the file actually landed. Match
    // leniently (case-insensitive, by filename) so a slightly different saved
    // name doesn't read as a failure when the download actually succeeded.
    ref.invalidate(localModelsProvider);
    final target = trimmed.contains(':') ? trimmed.split(':').last : null;
    final models = ref.read(localModelsProvider);
    bool landed(String t) {
      final want = t.toLowerCase();
      return models.any((m) {
        final name = m.name.toLowerCase();
        return name == want || name.endsWith(want) || name.contains(want);
      });
    }

    if (target == null || landed(target)) {
      state = ModelPullDone(target ?? trimmed);
    } else {
      state = const ModelPullFailed(
          "The download finished but the model couldn't be found afterwards. "
          'Check the model name and try again.');
    }
  }

  void reset() => state = const ModelPullIdle();
}
