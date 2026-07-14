import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_sync_controller.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';

/// Where the first-run installer is as a whole.
///
/// The per-step detail the screen draws lives in [installerRowsProvider], which
/// reads it off what is actually on the machine. This is only the overall
/// verdict: are we still working, can the user go in, did we stop.
sealed class InstallerState {
  const InstallerState();
}

/// Not started — the screen offers the button.
class InstallerIdle extends InstallerState {
  const InstallerIdle();
}

class InstallerRunning extends InstallerState {
  const InstallerRunning();
}

/// Everything is in place; the app is usable.
class InstallerDone extends InstallerState {
  const InstallerDone();
}

/// A step stopped. The screen shows which one (from the rows) and offers a
/// retry; the user can also skip into the app and use someone else's engine.
class InstallerFailed extends InstallerState {
  const InstallerFailed();
}

/// The user chose to go in without setting this computer up as a host. They can
/// still chat on a grid someone else hosts, and finish setup later from Engines.
class InstallerSkipped extends InstallerState {
  const InstallerSkipped();
}

final installerControllerProvider =
    NotifierProvider<InstallerController, InstallerState>(
      InstallerController.new,
    );

/// Drives first-run setup up to the point the user can chat: make sure they have
/// a grid, then install the engine and the assistant. The model is deliberately
/// left out — it's several GB, so it downloads in the background afterwards (see
/// BackgroundModelController), and sharing waits for it there too.
///
/// It orchestrates rather than re-implements: each phase is an existing
/// controller, so the installer screen and the Engines tab can never drift into
/// two different ideas of how a machine gets set up.
class InstallerController extends Notifier<InstallerState> {
  @override
  InstallerState build() => const InstallerIdle();

  /// Runs the sequence up to a usable app. Stops at the first step that fails —
  /// a later step depends on the one before it (no grid, nothing to set up on).
  /// Sharing and the model download are left to the background once the user is
  /// in, so this finishes as soon as the engine and assistant are installed.
  Future<void> run() async {
    if (state is InstallerRunning) return;
    state = const InstallerRunning();

    if (!await _ensureGrid()) {
      state = const InstallerFailed();
      return;
    }

    if (!await _installWhatsMissing()) {
      state = const InstallerFailed();
      return;
    }

    state = const InstallerDone();
  }

  /// Go in without hosting. Setup can be finished later from the Engines tab.
  void skip() => state = const InstallerSkipped();

  /// Stops the install in flight and returns to the start, so Cancel leaves no
  /// download running in the background.
  void cancel() {
    ref.read(nodeSetupControllerProvider.notifier).cancel();
    state = const InstallerIdle();
  }

  /// The user's grid, created for them on the server at sign-up. Pull the latest
  /// grid list so it's here locally, then confirm one is selectable — everything
  /// downstream needs a grid (you can't share an engine with nowhere to share it).
  Future<bool> _ensureGrid() async {
    if (ref.read(selectedNetworkProvider) != null) return true;
    await ref.read(gridSyncControllerProvider.notifier).sync();
    return ref.read(selectedNetworkProvider) != null;
  }

  /// Installs the gaps that must be in place before the user goes in: the engine
  /// and the assistant. The model is excluded ([buildSetupPlan] with
  /// `includeModel: false`) — it downloads in the background. A machine that
  /// already has a piece skips it (the row shows as done).
  Future<bool> _installWhatsMissing() async {
    final caps = await ref.read(nodeCapabilitiesProvider.future);
    final plan = buildSetupPlan(caps, includeModel: false);
    if (plan.isEmpty) return true;

    await ref.read(nodeSetupControllerProvider.notifier).run(plan);
    return ref.read(nodeSetupControllerProvider) is! NodeSetupFailed;
  }
}
