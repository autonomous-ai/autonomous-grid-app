import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/host_arch.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
import '../../../core/context_length.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import '../../network/logic/enable_provider_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';

/// The last mile of the hands-off setup: once this computer has an engine and a
/// model, share them on the user's grid so they can actually chat.
///
/// Node setup stops after installing the engine and downloading a model — which
/// left a computer that was ready to host but wasn't hosting, and a user staring
/// at a grid with no models on it. This finishes the job: grant the provider
/// role if it's missing, then `grid join --serve`.
///
/// **Setup only — never on launch.** Opening the app doesn't put the machine
/// back to work: serving spends the user's own GPU, so restarting an engine they
/// stopped (or that died with the machine) is their call, made on the Engines
/// tab. The single caller is the first-run model download finishing; a launch
/// hook here is a regression, not a convenience.
///
/// A user who *wants* that has the opt-in instead — the "start this when Grid
/// opens" box in the engine block, off by default, which starts exactly the
/// model they named through [AutoServeStarter]. That is a decision they made;
/// this controller acting on launch would be one nobody made.
sealed class AutoHostState {
  const AutoHostState();
}

/// Not sharing, and nothing to say — the resting state.
class AutoHostIdle extends AutoHostState {
  const AutoHostIdle();
}

/// Sharing is being set up. [message] is what's happening, in the user's terms.
class AutoHostRunning extends AutoHostState {
  const AutoHostRunning(this.message);
  final String message;
}

/// This computer is now serving a model on the grid.
class AutoHostDone extends AutoHostState {
  const AutoHostDone();
}

/// Sharing couldn't be set up. [message] is user-facing; the engine is still
/// installed, so the user can retry from the Engines tab.
class AutoHostFailed extends AutoHostState {
  const AutoHostFailed(this.message);
  final String message;
}

/// Whether this machine can host at all ([supportsBuiltInEngine]), behind a
/// provider so the policy — and everything gated on it — is testable without
/// depending on the machine the tests happen to run on.
final supportsBuiltInEngineProvider = Provider<bool>(
  (_) => supportsBuiltInEngine,
);

final autoHostControllerProvider =
    NotifierProvider<AutoHostController, AutoHostState>(AutoHostController.new);

class AutoHostController extends Notifier<AutoHostState> {
  /// Sharing is attempted once per session. A user who stops the engine meant to
  /// stop it — the app must not start it again behind their back.
  bool _attempted = false;

  @override
  AutoHostState build() => const AutoHostIdle();

  /// Share this computer's engine on the active grid, if everything it needs is
  /// in place. Safe to call more than once: it no-ops until the preconditions
  /// hold, and it runs at most once per session. Called when the first-run model
  /// download finishes — and nowhere else, by design (see the note above).
  Future<void> startIfReady() async {
    if (_attempted || !ref.read(supportsBuiltInEngineProvider)) return;

    final network = ref.read(selectedNetworkProvider);
    if (network == null) return;
    // Only on a grid the user administers: sharing needs the provider role, and
    // only an owner can grant it to themselves. A guest on someone else's grid
    // is a consumer — nothing to do.
    if (!network.isOwner && !network.isProvider) return;
    // Never onto a public grid unasked: everyone on it could then run models on
    // this computer. Putting a machine in front of strangers is a decision the
    // user makes on the Engines tab, not something setup does for them.
    if (network.isPublic) return;

    if (!ref.read(engineStatusProvider).llamaInstalled) return;
    final models = ref.read(modelGroupsProvider);
    if (models.isEmpty) return;

    // Adopt an engine that outlived a restart before deciding to start one, or
    // we'd join a grid this machine is already serving.
    final runner = ref.read(providerRunControllerProvider.notifier);
    runner.reconcile(network.networkId);
    // One machine serves one model at a time.
    if (ref.read(providerRunControllerProvider) is! ProviderRunIdle) return;

    _attempted = true;
    final model = models.first.primary.name;

    if (!network.isProvider && !await _becomeProvider(network.networkId)) {
      return;
    }

    state = const AutoHostRunning('Sharing this computer on your grid…');
    await runner.startLocal(
      network: network.networkId,
      model: model,
      advertiseAs: deriveAdvertiseName(model),
      ctxSize: await _contextLengthFor(model),
    );

    final run = ref.read(providerRunControllerProvider);
    state = run is ProviderRunFailed
        ? AutoHostFailed(run.message)
        : const AutoHostDone();
  }

  /// Grants this user the provider role on [networkId]. Returns false (and sets
  /// the failed state) when it doesn't work — sharing can't proceed without it.
  Future<bool> _becomeProvider(String networkId) async {
    final email = ref.read(sessionProvider).userEmail;
    if (email == null) {
      state = const AutoHostFailed(
        "Couldn't set up sharing: you're signed out.",
      );
      return false;
    }

    state = const AutoHostRunning('Setting up sharing…');
    await ref
        .read(enableProviderControllerProvider.notifier)
        .enable(networkId: networkId, email: email);

    final result = ref.read(enableProviderControllerProvider);
    if (result is! EnableFailed) return true;

    state = AutoHostFailed(
      "Couldn't set up sharing on your grid: ${result.message}",
    );
    return false;
  }

  /// The context window to serve [model] with — its own maximum, capped to the
  /// default. Null when the model's maximum can't be read, which leaves the
  /// engine on its own default rather than guessing.
  Future<int?> _contextLengthFor(String model) async {
    final max = await ref.read(modelMaxContextProvider(model).future);
    return max == null ? null : defaultContextLength(max);
  }

  /// Clears a failure so the banner goes away. Does not re-arm sharing — the
  /// user retries from the Engines tab, where they can see what they're doing.
  void dismiss() => state = const AutoHostIdle();
}
