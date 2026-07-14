import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/providers.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import 'auto_host_controller.dart';
import 'node_capabilities.dart';
import 'node_setup_plan.dart';

/// Where the background model download stands, as a sealed state so the top bar
/// switches exhaustively instead of juggling nullable progress/error fields.
sealed class ModelDownloadState {
  const ModelDownloadState();
}

/// Nothing downloading — the resting state, before it starts and after it's done.
class ModelDownloadIdle extends ModelDownloadState {
  const ModelDownloadIdle();
}

/// The model is downloading. [progress] is the current bar, null until the first
/// line parses (the top bar then shows an indeterminate spinner).
class ModelDownloadRunning extends ModelDownloadState {
  const ModelDownloadRunning({this.progress});
  final DownloadProgress? progress;
}

/// The download finished and the model is on disk.
class ModelDownloadDone extends ModelDownloadState {
  const ModelDownloadDone();
}

/// The download stopped. [message] is a plain line for the top bar; the user can
/// retry from the Engines tab, where the whole setup is visible.
class ModelDownloadFailed extends ModelDownloadState {
  const ModelDownloadFailed(this.message);
  final String message;
}

final backgroundModelControllerProvider =
    NotifierProvider<BackgroundModelController, ModelDownloadState>(
      BackgroundModelController.new,
    );

/// Downloads the recommended model in the background after first-run setup, so
/// the user reaches chat without waiting several GB. On success it shares the
/// model on the grid ([AutoHostController]).
///
/// Runs at most once per session, and only on a machine that can host, already
/// has the engine, and has no model yet — a consumer-only computer, or one still
/// missing its engine, is left alone.
class BackgroundModelController extends Notifier<ModelDownloadState> {
  bool _attempted = false;

  @override
  ModelDownloadState build() => const ModelDownloadIdle();

  /// Start the download when the preconditions hold. Safe to call whenever the
  /// shell mounts — it no-ops until they do, and never runs twice.
  Future<void> startIfNeeded() async {
    if (_attempted) return;
    if (!ref.read(supportsBuiltInEngineProvider)) return;
    if (!ref.read(engineStatusProvider).llamaInstalled) return;
    if (ref.read(localModelsProvider).isNotEmpty) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) return;

    // Claim the slot before the first await, so a second call (the shell fires
    // this from more than one place) can't start a second download.
    _attempted = true;

    final caps = await ref.read(nodeCapabilitiesProvider.future);
    final step = modelPullStep(caps);
    if (step == null) return; // a model landed while we were checking

    state = const ModelDownloadRunning();
    try {
      await for (final progress in service.pull(step.args)) {
        state = ModelDownloadRunning(progress: progress);
      }
    } on Object {
      state = const ModelDownloadFailed(
        "Couldn't finish downloading your model. Open Engines to try again.",
      );
      return;
    }

    ref.invalidate(localModelsProvider);
    ref.invalidate(nodeCapabilitiesProvider);
    state = const ModelDownloadDone();

    // There's a model now — share it on the grid. Idempotent and guarded, so a
    // user with no grid to share on simply no-ops.
    await ref.read(autoHostControllerProvider.notifier).startIfReady();
  }
}
