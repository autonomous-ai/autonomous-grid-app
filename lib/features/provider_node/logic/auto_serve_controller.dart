import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/auto_serve_store.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import 'provider_run_controller.dart';

/// Starts the model the user asked to have started, when the app opens.
///
/// The rule everywhere else in this app is that **opening it never puts the
/// computer to work** — serving spends the operator's own GPU, so an engine
/// that stopped stays stopped until they say otherwise (see [AutoHostController],
/// which is setup-only for exactly this reason). This is the one exception, and
/// only because the user ticked a box that says so, for one named model on one
/// named grid.
///
/// It stays deliberately timid. Nothing starts unless every one of these holds,
/// and none of them is worth a dialog on launch — the box can be unticked in
/// the engine block, which is also where a failure will be visible:
///  - the setting is on and names a model and a grid;
///  - that grid is the one the app is actually on;
///  - the engine is installed and the model is still on disk, whole;
///  - nothing is already serving here (an engine that outlived the app is
///    adopted first, so a relaunch never joins a grid twice).
final autoServeStarterProvider = Provider<AutoServeStarter>(
  AutoServeStarter.new,
);

class AutoServeStarter {
  AutoServeStarter(this._ref);

  final Ref _ref;

  /// Guards against a second run in the same session: the shell can call this
  /// again (a hot reload, a re-mount), and the user who stops the engine after
  /// launch means to stop it.
  bool _attempted = false;

  Future<void> startIfEnabled() async {
    if (_attempted) return;

    final prefs = _ref.read(autoServePrefsProvider);
    if (!prefs.isArmed) return;

    final network = _ref.read(selectedNetworkProvider);
    if (network == null || network.networkId != prefs.networkId) return;
    if (!_ref.read(engineStatusProvider).llamaInstalled) return;

    // The model has to be all here. A split set missing a shard is on disk
    // without being loadable, and starting it produces an engine that fails at
    // the far end of a launch nobody is watching.
    final model = prefs.model!;
    final group = _ref
        .read(modelGroupsProvider)
        .where((g) => g.primary.name == model && g.isComplete);
    if (group.isEmpty) return;

    final runner = _ref.read(providerRunControllerProvider.notifier);
    runner.reconcile(network.networkId);
    if (_ref.read(providerRunControllerProvider) is! ProviderRunIdle) return;

    _attempted = true;
    await runner.startLocal(
      network: network.networkId,
      model: model,
      advertiseAs: prefs.advertiseAs ?? deriveAdvertiseName(model),
      ctxSize: prefs.ctxSize,
    );
  }
}
