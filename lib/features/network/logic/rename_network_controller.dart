import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';
import 'grid_name.dart';

/// The `PATCH /v1/grid/networks/{network_id}` call, behind a provider so tests
/// can swap in a fake without a real HTTP round-trip. Defaults to the live
/// client — the same seam as [managedNetworkDeleteProvider].
typedef ManagedNetworkRenameFn =
    Future<(bool, ManagedNetworkError?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
      required String name,
    });

final managedNetworkRenameProvider = Provider<ManagedNetworkRenameFn>(
  (ref) => ManagedNetworkClient.rename,
);

final renameNetworkControllerProvider =
    NotifierProvider<RenameNetworkController, RenameNetworkState>(
      RenameNetworkController.new,
    );

/// Where a grid rename stands. Modelled as a sealed state so the dialog switches
/// exhaustively (spinner while saving) instead of juggling booleans.
sealed class RenameNetworkState {
  const RenameNetworkState();
}

class RenameNetworkIdle extends RenameNetworkState {
  const RenameNetworkIdle();
}

class RenameNetworkSaving extends RenameNetworkState {
  const RenameNetworkSaving();
}

class RenameNetworkDone extends RenameNetworkState {
  const RenameNetworkDone();
}

class RenameNetworkFailed extends RenameNetworkState {
  const RenameNetworkFailed(this.message);
  final String message;
}

/// Renames a grid via the control-plane API, then refreshes the local grid list
/// with `grid sync` so the new name reaches the sidebar, top bar and tray — the
/// same call-then-sync shape as [DeleteNetworkController].
///
/// Only the display name changes: the grid keeps its id, so tokens, joined
/// engines and the Base URL are untouched.
class RenameNetworkController extends Notifier<RenameNetworkState> {
  @override
  RenameNetworkState build() => const RenameNetworkIdle();

  /// Renames [networkId] to [name]. Returns null on success or a user-facing
  /// message on failure (the [state] carries the same for the dialog; the return
  /// value lets the caller act without reading state after the widget may be
  /// gone).
  Future<String?> rename({
    required String networkId,
    required String name,
  }) async {
    final session = ref.read(sessionProvider);
    final token = session.sessionToken;
    if (token == null || token.isEmpty) {
      return _fail('Sign in before renaming a grid.');
    }

    final trimmed = name.trim();
    final invalid = gridNameError(
      trimmed,
      takenNames: session.networks
          .where((n) => n.networkId != networkId)
          .map((n) => n.name),
    );
    if (invalid != null) return _fail(invalid);

    // The name the local `state.json` active pointer may hold — the CLI accepts
    // either a name or an id there, and `grid sync` is about to retire this one.
    final previousName = session.byName(networkId)?.name;

    state = const RenameNetworkSaving();

    final apiUrl = ref.read(gridApiUrlProvider);
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'PATCH ${ManagedNetworkClient.renameEndpoint(apiUrl, networkId)}',
      detail: CommandDetail.json(ManagedNetworkClient.renameBody(trimmed)),
    );
    final (ok, error) = await ref.read(managedNetworkRenameProvider)(
      apiUrl: apiUrl,
      sessionToken: token,
      networkId: networkId,
      name: trimmed,
    );
    // Debug tab gets the HTTP status + raw server body; the UI shows only the
    // friendly message.
    log.finish(
      logId,
      exitCode: error?.statusCode ?? (ok ? 200 : null),
      error: error?.debugDetail,
    );

    if (!ok) return _fail(error?.message ?? 'Could not rename the grid.');

    await _syncLocalList(networkId: networkId, previousName: previousName);
    state = const RenameNetworkDone();
    return null;
  }

  void reset() => state = const RenameNetworkIdle();

  String _fail(String message) {
    state = RenameNetworkFailed(message);
    return message;
  }

  /// Pull the new name into `~/.grid` with `grid sync`, then refresh the session
  /// so every view of the name recomputes. Best-effort: the rename already
  /// landed server-side, so a sync hiccup only leaves a stale local name.
  Future<void> _syncLocalList({
    required String networkId,
    required String? previousName,
  }) async {
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
    await _repointActiveGrid(networkId: networkId, previousName: previousName);
    ref.invalidate(sessionProvider);
  }

  /// Re-point `grid use` at the grid *by id* when the active pointer still holds
  /// the name we just retired. Without this, renaming the grid you're using
  /// leaves `state.json` naming a grid that no longer exists, and the app (and
  /// the CLI) fall back to some other grid.
  Future<void> _repointActiveGrid({
    required String networkId,
    required String? previousName,
  }) async {
    final active = ref.read(activeRemoteGridProvider);
    if (active == null || active != previousName) return;
    final service = ref.read(gridCliServiceProvider);
    await service?.run(['use', networkId]);
    ref.invalidate(activeRemoteGridProvider);
  }
}
