import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/onboarding_store.dart';
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

/// Whether the automatic model download may run: only once the user has chosen
/// to run a model on this computer (onboarding's "run local" path).
///
/// Before onboarding branched, any Mac with the engine and no model downloaded
/// one automatically. That became a deliberate choice — a user who picked a
/// hosted provider or chose to wait for a teammate must not be handed a
/// several-GB download they said no to. Overridable in tests.
///
/// **TODO(BE): nothing sets this any more.** Onboarding stopped asking which
/// model to connect on 2026-08-26, and that screen was the only writer of
/// [OnboardingDecision]. The decision is persisted in
/// `~/.grid/app/onboarding.json`, so this stays true on installs that answered
/// `local` before that date, and is permanently false on every install made
/// since — which means the background download, [AutoHostController]'s
/// automatic `grid join --serve`, the top bar's download pill and
/// [NoModelYet]'s downloading state are all now reachable by old installs
/// only. That is a deliberate hold, not an oversight: deleting the
/// chain would take auto-share away from the users who *do* still reach it. New
/// users set an engine up from **Share Intelligence** instead, which is the
/// door chat's empty state already sends them to. Decide it properly rather than
/// letting it rot — either give this a new writer, or remove the chain and
/// accept the loss for old installs.
final localModelChosenProvider = Provider<bool>(
  (ref) => ref.watch(onboardingDecisionProvider) == OnboardingDecision.local,
);

final backgroundModelControllerProvider =
    NotifierProvider<BackgroundModelController, ModelDownloadState>(
      BackgroundModelController.new,
    );

/// Downloads the recommended model in the background after first-run setup, so
/// the user reaches chat without waiting several GB. On success it shares the
/// model on the grid ([AutoHostController]).
///
/// Runs at most once per session, and only when the user chose to run a model on
/// this computer and the machine can host, already has the engine, and has no
/// model yet — a computer that picked a hosted provider, is waiting for a
/// teammate, or is still missing its engine is left alone.
class BackgroundModelController extends Notifier<ModelDownloadState> {
  bool _attempted = false;

  @override
  ModelDownloadState build() => const ModelDownloadIdle();

  /// Start the download when the preconditions hold. Safe to call whenever the
  /// shell mounts — it no-ops until they do, and never runs twice.
  Future<void> startIfNeeded() async {
    if (_attempted) return;
    if (!ref.read(supportsBuiltInEngineProvider)) return;
    // Only when the user chose to run a model on this computer — not on a machine
    // that picked a hosted provider or is waiting for a teammate.
    if (!ref.read(localModelChosenProvider)) return;
    if (!ref.read(engineStatusProvider).llamaInstalled) return;
    if (ref.read(localModelsProvider).isNotEmpty) return;
    // A download is already on disk as a `.gguf.part`. Whether it's still running
    // or was interrupted, kicking off a fresh pull here would duplicate the work
    // — or, worse, write the same part-file concurrently and corrupt it. Leave it
    // to resume from the Engines tab.
    if (ref.read(downloadingModelsProvider).isNotEmpty) return;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) return;

    // Claim the slot before the first await, so a second call (the shell fires
    // this from more than one place) can't start a second download.
    _attempted = true;

    final caps = await ref.read(nodeCapabilitiesProvider.future);
    final step = modelPullStep(caps);
    if (step == null) return; // a model landed while we were checking

    final analytics = ref.read(analyticsProvider);
    state = const ModelDownloadRunning();
    analytics.modelDownloadStarted();
    try {
      await for (final progress in service.pull(step.args)) {
        state = ModelDownloadRunning(progress: progress);
      }
    } on Object {
      state = const ModelDownloadFailed(
        "Couldn't finish downloading your model. Open Engines to try again.",
      );
      analytics.modelDownloadFailed('pull_failed');
      return;
    }

    ref.invalidate(localModelsProvider);
    ref.invalidate(downloadingModelsProvider);
    ref.invalidate(nodeCapabilitiesProvider);
    state = const ModelDownloadDone();
    analytics.modelDownloadCompleted();

    // There's a model now — share it on the grid. Idempotent and guarded, so a
    // user with no grid to share on simply no-ops.
    await ref.read(autoHostControllerProvider.notifier).startIfReady();
  }
}
