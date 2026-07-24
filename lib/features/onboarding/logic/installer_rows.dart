import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import '../../agent/logic/hermes_tool.dart';
import '../../network/logic/grid_sync_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';
import 'installer_controller.dart';
import 'installer_stage.dart';

/// The installer checklist.
///
/// Each row's status is derived from what is *actually* on the machine — the
/// agent binary, the selected grid — not from a flag the installer sets. So a
/// step can't claim "done" when it isn't, and a machine that already had the
/// assistant shows it ticked without installing twice. Neither the engine nor
/// the model is here: running a model on this computer is a choice the user makes
/// on the screen after setup (see `OnboardingChoiceScreen`).
final installerRowsProvider = Provider<List<InstallerRow>>((ref) {
  final setup = ref.watch(nodeSetupControllerProvider);

  return [
    _gridRow(ref),
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

/// Whether this computer still needs the first-run installer.
///
/// Only a missing assistant holds the user here now. The engine and model aren't
/// gates: running a model on this computer is a choice on the screen after this
/// one, and the model downloads in the background once the user is in. The
/// assistant, though, is not Mac-only: `grid agent install` needs no Homebrew
/// and no admin rights and runs on every OS, so the installer is shown wherever
/// it's missing — Windows and Linux included — instead of installing the agent
/// silently in the background there. Only the built-in *engine* stays Mac-gated,
/// and that's decided on the choose-a-model screen after this one.
final installerNeededProvider = Provider<bool>((ref) {
  return !ref.watch(hermesInstalledProvider);
});

/// Whether to show the installer instead of the app.
///
/// Once the user is in, they stay in: a finished or skipped install never puts
/// the screen back. Shown on every OS while the assistant is missing; a machine
/// that already has it (or a returning user) never sees it.
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
