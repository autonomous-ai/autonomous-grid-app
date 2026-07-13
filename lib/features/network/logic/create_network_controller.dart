import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';
import 'default_grid_name.dart';

/// The `POST /v1/grid/managed-networks` call, behind a provider so tests can
/// swap in a fake without a real HTTP round-trip. Defaults to the live client.
typedef ManagedNetworkCreateFn
    = Future<(ManagedNetwork?, ManagedNetworkError?)> Function({
  required String apiUrl,
  required String sessionToken,
  required String name,
  required ManagedNetworkType type,
});

final managedNetworkCreateProvider = Provider<ManagedNetworkCreateFn>(
  (ref) => ManagedNetworkClient.create,
);

final createNetworkControllerProvider =
    NotifierProvider<CreateNetworkController, CreateNetworkState>(
        CreateNetworkController.new);

sealed class CreateNetworkState {
  const CreateNetworkState();
}

class CreateNetworkIdle extends CreateNetworkState {
  const CreateNetworkIdle();
}

/// A create is in flight. [auto] marks the starter grid the app provisions by
/// itself (see [CreateNetworkController.createFirstGridIfNeeded]) — nobody asked
/// for it on screen, so only that case is announced in the app-wide banner; a
/// create the user started from the dialog already has a spinner in front of them.
class CreateNetworkSubmitting extends CreateNetworkState {
  const CreateNetworkSubmitting({this.auto = false});
  final bool auto;
}

/// The network was created. [joinWarning] is set when the network exists on the
/// server but couldn't be added to the local list (so the UI can nudge).
class CreateNetworkDone extends CreateNetworkState {
  const CreateNetworkDone(this.network, {this.joinWarning, this.auto = false});
  final ManagedNetwork network;
  final String? joinWarning;

  /// Whether this was the app's own starter grid — see [CreateNetworkSubmitting].
  final bool auto;
}

class CreateNetworkFailed extends CreateNetworkState {
  const CreateNetworkFailed(this.message, {this.auto = false});
  final String message;

  /// Whether the failed create was the app's own — see [CreateNetworkSubmitting].
  /// A silent failure here would leave the user with no grid and no explanation.
  final bool auto;
}

/// Creates a managed (hosted) grid via the control-plane API, then refreshes the
/// local grid list with `grid sync` and makes the new grid active with
/// `grid use` — the same create-then-refresh shape as [EnableProviderController].
class CreateNetworkController extends Notifier<CreateNetworkState> {
  @override
  CreateNetworkState build() => const CreateNetworkIdle();

  /// Creates a grid. [auto] flags the app's own starter grid, so the app-wide
  /// banner can announce a create the user never asked for (and its failure).
  Future<void> submit({
    required String name,
    required ManagedNetworkType type,
    bool auto = false,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state = CreateNetworkFailed('Enter a name for your grid.', auto: auto);
      return;
    }

    final session = ref.read(sessionProvider);
    final token = session.sessionToken;
    if (token == null || token.isEmpty) {
      state = CreateNetworkFailed('Sign in before creating a grid.', auto: auto);
      return;
    }

    state = CreateNetworkSubmitting(auto: auto);

    final apiUrl = ref.read(gridApiUrlProvider);
    final create = ref.read(managedNetworkCreateProvider);

    // Surface the HTTP call in the Debug tab, just like the local-chat path.
    final log = ref.read(commandLogProvider.notifier);
    final logId =
        log.begin(CliCallKind.http, 'POST ${ManagedNetworkClient.endpoint(apiUrl)}');
    final (network, error) = await create(
      apiUrl: apiUrl,
      sessionToken: token,
      name: trimmed,
      type: type,
    );
    // Debug tab gets the HTTP status + raw server body (debugDetail); the dialog
    // shows only the friendly message.
    log.finish(
      logId,
      exitCode: error?.statusCode ?? (network != null ? 200 : null),
      error: error?.debugDetail,
    );

    if (network == null) {
      state = CreateNetworkFailed(
        error?.message ?? 'Could not create the grid.',
        auto: auto,
      );
      return;
    }

    final joinWarning = await _syncAndSelect(network.networkId);
    ref.invalidate(sessionProvider);
    state = CreateNetworkDone(network, joinWarning: joinWarning, auto: auto);
  }

  /// Provision the user's own grid, named after them ("Đức AI Grid" from the
  /// profile name, else "Huy AI Grid" from huy@gmail.com). Fired when the
  /// signed-in shell appears (see `HomeShell`), so it covers both a fresh login
  /// and simply re-opening the app.
  ///
  /// The gate is *owning* a grid, not merely being on one: someone invited to a
  /// colleague's grid has networks but can't share a model anywhere, which left
  /// them without the one grid every user needs. No-ops once they own one, and
  /// while a create is already in flight, so it's safe to call more than once
  /// and never races a manual create. Delegates to [submit] for the actual
  /// create + local join + session refresh.
  Future<void> createFirstGridIfNeeded() async {
    if (state is CreateNetworkSubmitting) return;
    final session = ref.read(sessionProvider);
    if (session.networks.any((n) => n.isOwner)) return;
    await submit(
      name: defaultGridName(name: session.userName, email: session.userEmail),
      type: ManagedNetworkType.starterDefault,
      auto: true,
    );
  }

  void reset() => state = const CreateNetworkIdle();

  /// Pull the freshly-created grid into `~/.grid` and make it the active one.
  ///
  /// `grid sync` re-fetches the grid list + per-grid tokens from the saved
  /// session (no browser), so the new grid lands locally; `grid use` then points
  /// the active selection at it. Returns a warning when the grid exists
  /// server-side but couldn't be synced locally; an expired session is flagged
  /// to the app instead (so it prompts a re-login) rather than surfaced here.
  Future<String?> _syncAndSelect(String networkId) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      return 'Created, but the grid CLI was not found to add it to your list.';
    }
    final sync = await service.run(['sync']);
    if (sync.sessionExpired) {
      await ref.read(sessionExpiryProvider.notifier).onExpired();
      return null;
    }
    if (!sync.ok) {
      return 'Created, but refreshing your grid list failed: ${sync.errorMessage}';
    }
    // Best-effort: point the active selection at the grid we just made.
    await service.run(['use', networkId]);
    return null;
  }
}
