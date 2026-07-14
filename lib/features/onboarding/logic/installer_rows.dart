import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import '../../agent/logic/hermes_tool.dart';
import '../../models/logic/engine_status.dart';
import '../../network/logic/grid_sync_controller.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import 'installer_controller.dart';
import 'installer_stage.dart';

/// The installer checklist.
///
/// Each row's status is derived from what is *actually* on the machine — the
/// engine binary, the agent — not from a flag the installer sets. So a step
/// can't claim "done" when it isn't, and a machine that already had the engine
/// shows it ticked without installing twice. The model isn't here: it downloads
/// in the background after the user is in (see BackgroundModelController).
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
      InstallerStage.agent,
      SetupAction.installAgent,
      installed: ref.watch(hermesInstalledProvider),
      setup: setup,
    ),
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

/// Whether this computer still needs setting up as a host.
final installerNeededProvider = Provider<bool>((ref) {
  if (!ref.watch(supportsBuiltInEngineProvider)) return false;
  final engine = ref.watch(engineStatusProvider).llamaInstalled;
  final agent = ref.watch(hermesInstalledProvider);
  // The model isn't a gate: it downloads in the background once the user is in,
  // so only a missing engine or assistant holds them at the installer.
  return !(engine && agent);
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
  // The grid is created for the user on the server; here it's pulled in with
  // `grid sync`, so that's what this row reflects until one lands locally.
  return switch (ref.watch(gridSyncControllerProvider)) {
    GridSyncRunning() => const InstallerRow(
      stage: InstallerStage.grid,
      status: InstallStatus.running,
    ),
    GridSyncFailed(:final message) => InstallerRow(
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
