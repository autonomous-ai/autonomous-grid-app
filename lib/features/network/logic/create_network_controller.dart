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
typedef ManagedNetworkCreateFn = Future<(ManagedNetwork?, String?)> Function({
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

class CreateNetworkSubmitting extends CreateNetworkState {
  const CreateNetworkSubmitting();
}

/// The network was created. [joinWarning] is set when the network exists on the
/// server but couldn't be added to the local list (so the UI can nudge).
class CreateNetworkDone extends CreateNetworkState {
  const CreateNetworkDone(this.network, {this.joinWarning});
  final ManagedNetwork network;
  final String? joinWarning;
}

class CreateNetworkFailed extends CreateNetworkState {
  const CreateNetworkFailed(this.message);
  final String message;
}

/// Creates a managed (hosted) grid via the control-plane API, then pulls it
/// into `~/.grid` with `grid network join` so it shows up in the list — the
/// same create-then-refresh shape as [EnableProviderController].
class CreateNetworkController extends Notifier<CreateNetworkState> {
  @override
  CreateNetworkState build() => const CreateNetworkIdle();

  Future<void> submit({
    required String name,
    required ManagedNetworkType type,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state = const CreateNetworkFailed('Enter a name for your grid.');
      return;
    }

    final session = ref.read(sessionProvider);
    final token = session.sessionToken;
    if (token == null || token.isEmpty) {
      state = const CreateNetworkFailed('Sign in before creating a grid.');
      return;
    }

    state = const CreateNetworkSubmitting();

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
    log.finish(logId, exitCode: error == null ? 200 : null, error: error);

    if (network == null) {
      state = CreateNetworkFailed(error ?? 'Could not create the grid.');
      return;
    }

    final joinWarning = await _joinLocally(network.networkId);
    await _sync();
    ref.invalidate(sessionProvider);
    state = CreateNetworkDone(network, joinWarning: joinWarning);
  }

  /// Provision the user's very first grid right after sign-in, named after them
  /// ("Huy Grid" for huy@gmail.com). No-op once they already have a grid, so it
  /// only ever fires for a brand-new account. Delegates to [submit] for the
  /// actual create + local join + session refresh.
  Future<void> createFirstGridIfNeeded() async {
    final session = ref.read(sessionProvider);
    if (session.networks.isNotEmpty) return;
    await submit(
      name: defaultGridName(session.userEmail),
      type: ManagedNetworkType.fallback,
    );
  }

  void reset() => state = const CreateNetworkIdle();

  /// Best-effort `grid sync` so the new grid's full state lands in `~/.grid`
  /// before we refresh the session. Failures are non-fatal (logged in Debug),
  /// except an expired session — flag that so the app prompts a re-login.
  Future<void> _sync() async {
    final result = await ref.read(gridCliServiceProvider)?.run(['sync']);
    if (result != null && result.sessionExpired) {
      await ref.read(sessionExpiryProvider.notifier).onExpired();
    }
  }

  /// Best-effort `grid network join` so the new grid lands in the local list.
  /// Returns a warning when it couldn't run — the grid still exists server-side.
  Future<String?> _joinLocally(String networkId) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      return 'Created, but the grid CLI was not found to add it to your list.';
    }
    final join = await service.run(['network', 'join', networkId]);
    if (!join.ok) {
      return 'Created, but joining locally failed: ${join.errorMessage}';
    }
    return null;
  }
}
