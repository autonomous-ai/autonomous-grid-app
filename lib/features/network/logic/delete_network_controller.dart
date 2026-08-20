import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';
import 'grid_choice.dart';

/// The `DELETE /v1/grid/managed-networks/{network_id}` call, behind a provider
/// so tests can swap in a fake without a real HTTP round-trip. Defaults to the
/// live client — the same seam as [managedNetworkCreateProvider].
typedef ManagedNetworkDeleteFn =
    Future<(bool, ManagedNetworkError?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
    });

final managedNetworkDeleteProvider = Provider<ManagedNetworkDeleteFn>(
  (ref) => ManagedNetworkClient.delete,
);

final deleteNetworkControllerProvider =
    NotifierProvider<DeleteNetworkController, DeleteNetworkState>(
      DeleteNetworkController.new,
    );

/// Where a grid deletion stands. Modelled as a sealed state so the button
/// switches exhaustively (spinner while deleting) instead of juggling booleans.
sealed class DeleteNetworkState {
  const DeleteNetworkState();
}

class DeleteNetworkIdle extends DeleteNetworkState {
  const DeleteNetworkIdle();
}

class DeleteNetworkDeleting extends DeleteNetworkState {
  const DeleteNetworkDeleting();
}

class DeleteNetworkDone extends DeleteNetworkState {
  const DeleteNetworkDone();
}

class DeleteNetworkFailed extends DeleteNetworkState {
  const DeleteNetworkFailed(this.message);
  final String message;
}

/// Deletes a managed (hosted) grid via the control-plane API, then refreshes the
/// local grid list with `grid sync` so the deleted grid drops out — the inverse
/// of [CreateNetworkController]. Deleting the grid you were on moves you to
/// another one and records it, rather than leaving a remembered id pointing at
/// something that no longer exists (see [_reselectIfChosenGridIsGone]).
class DeleteNetworkController extends Notifier<DeleteNetworkState> {
  @override
  DeleteNetworkState build() => const DeleteNetworkIdle();

  /// Deletes [networkId]. Returns `null` on success or a user-facing message on
  /// failure (the [state] carries the same for the button; the return value lets
  /// the caller show a toast without reading state after the widget may be gone).
  Future<String?> delete(String networkId) async {
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) {
      const message = 'Sign in before deleting a grid.';
      state = const DeleteNetworkFailed(message);
      return message;
    }

    state = const DeleteNetworkDeleting();

    final apiUrl = ref.read(gridApiUrlProvider);
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'DELETE ${ManagedNetworkClient.networkEndpoint(apiUrl, networkId)}',
      detail: const CommandDetail(authorized: true),
    );
    final (ok, error) = await ref.read(managedNetworkDeleteProvider)(
      apiUrl: apiUrl,
      sessionToken: token,
      networkId: networkId,
    );
    // Debug tab gets the HTTP status + raw server body; the UI shows only the
    // friendly message.
    log.finish(
      logId,
      exitCode: error?.statusCode ?? (ok ? 200 : null),
      error: error?.debugDetail,
    );

    if (!ok) {
      final message = error?.message ?? 'Could not delete the grid.';
      state = DeleteNetworkFailed(message);
      return message;
    }

    await _syncLocalList();
    _reselectIfChosenGridIsGone();
    state = const DeleteNetworkDone();
    return null;
  }

  void reset() => state = const DeleteNetworkIdle();

  /// Move the app onto another grid when the one just deleted was the user's.
  ///
  /// [SelectedNetwork] already falls back on its own, but only in memory: the
  /// remembered id on disk still names the deleted grid, so the *next* launch
  /// reads it as "the grid you chose is gone" and stops to ask again — a
  /// deletion done in Settings months earlier coming back as a first-run
  /// screen. Writing the fallback down finishes the deletion where it started.
  ///
  /// Deleting the last grid leaves nothing to fall back to, and that is left
  /// alone deliberately: there is no honest answer to record, and being asked
  /// on the next launch is then exactly right.
  void _reselectIfChosenGridIsGone() {
    final credentials = ref.read(sessionProvider);
    final chosen = ref.read(chatPrefsProvider).networkId;
    if (!needsGridChoice(credentials: credentials, chosenGridId: chosen)) {
      return;
    }
    final next = credentials.active;
    if (next == null) return;
    ref.read(selectedNetworkProvider.notifier).select(next);
  }

  /// Drop the deleted grid from `~/.grid` with `grid sync`, then refresh the
  /// session so the sidebar + selection recompute. Best-effort: the grid is
  /// already gone server-side, so a sync hiccup only leaves a stale local entry.
  Future<void> _syncLocalList() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      ref.invalidate(sessionProvider);
      return;
    }
    final sync = await service.run(['sync']);
    if (sync.sessionExpired) {
      await ref.read(sessionExpiryProvider.notifier).onExpired();
      return;
    }
    ref.invalidate(sessionProvider);
  }
}
