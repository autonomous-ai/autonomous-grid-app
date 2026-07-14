import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../auth/logic/session_controller.dart';
import '../../agent/logic/hermes_tool.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import '../../network/logic/create_network_controller.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import 'installer_controller.dart';
import 'installer_stage.dart';

/// The installer checklist.
///
/// Each row's status is derived from what is *actually* on the machine — the
/// engine binary, a model on disk, the agent, an engine serving — not from a
/// flag the installer sets. So a step can't claim "done" when it isn't, and a
/// machine that already had the engine shows it ticked without installing twice.
final installerRowsProvider = Provider<List<InstallerRow>>((ref) {
  final setup = ref.watch(nodeSetupControllerProvider);

  return [
    _gridRow(ref),
    _actionRow(
      InstallerStage.engine,
      SetupAction.installLlama,
      installed: ref.watch(engineStatusProvider).llamaInstalled,
      setup: setup,
    ),
    _actionRow(
      InstallerStage.model,
      SetupAction.pullModel,
      installed: ref.watch(localModelsProvider).isNotEmpty,
      setup: setup,
    ),
    _actionRow(
      InstallerStage.agent,
      SetupAction.installAgent,
      installed: ref.watch(hermesInstalledProvider),
      setup: setup,
    ),
    _shareRow(ref),
  ];
});

/// Live output of the step running now — what "Show details" reveals.
final installerLogProvider = Provider<List<String>>((ref) {
  final setup = ref.watch(nodeSetupControllerProvider);
  return switch (setup) {
    NodeSetupRunning(:final log) => log,
    NodeSetupFailed(:final log) => log,
    _ => const [],
  };
});

/// Download progress of the model step, or null when nothing is downloading.
final installerDownloadProvider = Provider<DownloadProgress?>((ref) {
  final setup = ref.watch(nodeSetupControllerProvider);
  return setup is NodeSetupRunning ? setup.progress : null;
});

/// Whether this computer still needs setting up as a host.
final installerNeededProvider = Provider<bool>((ref) {
  if (!ref.watch(supportsBuiltInEngineProvider)) return false;
  final engine = ref.watch(engineStatusProvider).llamaInstalled;
  final model = ref.watch(localModelsProvider).isNotEmpty;
  final agent = ref.watch(hermesInstalledProvider);
  return !(engine && model && agent);
});

/// Whether to show the installer instead of the app.
///
/// Once the user is in, they stay in: a finished or skipped install never puts
/// the screen back. A machine that can't host (Linux, Windows, or a guest on
/// someone else's grid) never sees it at all.
final showInstallerProvider = Provider<bool>((ref) {
  final state = ref.watch(installerControllerProvider);
  return switch (state) {
    InstallerDone() || InstallerSkipped() => false,
    InstallerRunning() || InstallerFailed() => true,
    InstallerIdle() => ref.watch(installerNeededProvider),
  };
});

InstallerRow _gridRow(Ref ref) {
  if (ref.watch(selectedNetworkProvider) != null) {
    return const InstallerRow(
      stage: InstallerStage.grid,
      status: InstallStatus.done,
    );
  }
  return switch (ref.watch(createNetworkControllerProvider)) {
    CreateNetworkSubmitting() => const InstallerRow(
      stage: InstallerStage.grid,
      status: InstallStatus.running,
    ),
    CreateNetworkFailed(:final message) => InstallerRow(
      stage: InstallerStage.grid,
      status: InstallStatus.failed,
      message: message,
    ),
    _ => const InstallerRow(
      stage: InstallerStage.grid,
      status: InstallStatus.pending,
    ),
  };
}

/// A row backed by one of the CLI setup steps ([SetupAction]).
InstallerRow _actionRow(
  InstallerStage stage,
  SetupAction action, {
  required bool installed,
  required NodeSetupState setup,
}) {
  if (installed) {
    return InstallerRow(stage: stage, status: InstallStatus.done);
  }
  if (setup is NodeSetupRunning && setup.current.action == action) {
    return InstallerRow(stage: stage, status: InstallStatus.running);
  }
  if (setup is NodeSetupFailed && setup.step.action == action) {
    return InstallerRow(
      stage: stage,
      status: InstallStatus.failed,
      message: setup.message,
    );
  }
  return InstallerRow(stage: stage, status: InstallStatus.pending);
}

InstallerRow _shareRow(Ref ref) {
  if (ref.watch(providerRunControllerProvider) is ProviderRunActive) {
    return const InstallerRow(
      stage: InstallerStage.share,
      status: InstallStatus.done,
    );
  }
  return switch (ref.watch(autoHostControllerProvider)) {
    AutoHostRunning() => const InstallerRow(
      stage: InstallerStage.share,
      status: InstallStatus.running,
    ),
    AutoHostFailed(:final message) => InstallerRow(
      stage: InstallerStage.share,
      status: InstallStatus.failed,
      message: message,
    ),
    _ => const InstallerRow(
      stage: InstallerStage.share,
      status: InstallStatus.pending,
    ),
  };
}
