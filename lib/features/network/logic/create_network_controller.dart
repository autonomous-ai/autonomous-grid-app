import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';

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

/// A create is in flight — the dialog shows a spinner in front of the user.
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

/// Creates a managed (hosted) grid via the control-plane API, then refreshes the
/// local grid list with `grid sync` and makes the new grid active with
/// `grid use` — the same create-then-refresh shape as [EnableProviderController].
class CreateNetworkController extends Notifier<CreateNetworkState> {
  @override
  CreateNetworkState build() => const CreateNetworkIdle();

  /// Creates a grid from the dialog, then refreshes the local list so the new
  /// grid shows up and becomes the active one.
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
      );
      return;
    }

    final joinWarning = await _syncAndSelect(network.networkId);
    ref.invalidate(sessionProvider);
    state = CreateNetworkDone(network, joinWarning: joinWarning);
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
