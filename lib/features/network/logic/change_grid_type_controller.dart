import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';

/// The `POST /managed-networks/{id}/network-type` call, behind a provider so
/// tests can swap in a fake without a real round-trip.
typedef SetNetworkTypeFn =
    Future<(bool, String?)> Function({
      required String apiUrl,
      required String sessionToken,
      required String networkId,
      required ManagedNetworkType type,
    });

final setNetworkTypeFnProvider = Provider<SetNetworkTypeFn>(
  (ref) => ManagedNetworkClient.setNetworkType,
);

sealed class ChangeGridTypeState {
  const ChangeGridTypeState();
}

class ChangeGridTypeIdle extends ChangeGridTypeState {
  const ChangeGridTypeIdle();
}

/// The owner picked a new rule and is being shown what it costs before it runs.
class ChangeGridTypeConfirming extends ChangeGridTypeState {
  const ChangeGridTypeConfirming(this.target);
  final ManagedNetworkType target;
}

/// In flight. Takes seconds: the control plane restarts the grid's server.
class ChangeGridTypeApplying extends ChangeGridTypeState {
  const ChangeGridTypeApplying(this.target);
  final ManagedNetworkType target;
}

class ChangeGridTypeFailed extends ChangeGridTypeState {
  const ChangeGridTypeFailed(this.message);
  final String message;
}

/// Changes who can reach a grid.
///
/// Confirmed before it runs, and the confirmation names what is LOST rather than
/// asking "are you sure?" — every rule takes something from somebody. Narrowing
/// cuts people off mid-session; opening up stops the grid billing for usage.
///
/// The apply is deliberately slow and says so: the server restarts the grid onto
/// the new rule, so it is briefly unreachable and everyone signed in reconnects
/// once. Hiding that behind a quick spinner would make a normal outage look like
/// a fault.
class ChangeGridTypeController extends Notifier<ChangeGridTypeState> {
  @override
  ChangeGridTypeState build() => const ChangeGridTypeIdle();

  /// The owner picked [target] while the grid is on [current].
  ///
  /// Picking the rule the grid is ALREADY on is not a change to confirm — it is
  /// how you back out of one, now that the field shows the pending pick rather
  /// than the saved value. This used to return early and do nothing, which left
  /// the field displaying the rule the owner had just abandoned: choose "Invite
  /// only", change your mind, choose "Anyone" again, and the field stayed on
  /// "Invite only" with no way back except closing the dialog.
  ///
  /// No request is sent here either way.
  void select({
    required ManagedNetworkType target,
    required ManagedNetworkType current,
  }) {
    if (target == current) {
      cancel();
      return;
    }
    state = ChangeGridTypeConfirming(target);
  }

  void cancel() => state = const ChangeGridTypeIdle();

  /// Applies [target] to [networkId]. Returns the failure message, or null when
  /// it landed — the caller refreshes the grid list and shows a toast.
  Future<String?> apply({
    required String networkId,
    required ManagedNetworkType target,
  }) async {
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) {
      const message = 'Sign in before changing who can reach this grid.';
      state = const ChangeGridTypeFailed(message);
      return message;
    }

    state = ChangeGridTypeApplying(target);
    final apiUrl = ref.read(gridApiUrlProvider);

    // Surfaced in the Debug tab like every other control-plane call — a slow
    // request with no visible record is the one people call a hang.
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'POST ${ManagedNetworkClient.networkTypeEndpoint(apiUrl, networkId)}',
      detail: CommandDetail.json(
        ManagedNetworkClient.networkTypeBody(target),
        authorized: true,
      ),
    );

    final (ok, error) = await ref.read(setNetworkTypeFnProvider)(
      apiUrl: apiUrl,
      sessionToken: token,
      networkId: networkId,
      type: target,
    );
    log.finish(logId, exitCode: ok ? 200 : null, error: error);

    if (!ok) {
      state = ChangeGridTypeFailed(error ?? 'Something went wrong.');
      return error ?? 'Something went wrong.';
    }
    // The rule now differs on the server, but the app reads `network_type` from
    // `~/.grid/credentials.toml`, which the CLI owns. Without re-syncing, the
    // picker keeps showing the OLD rule after a change that worked — the field
    // saying "Anyone" on a grid that is now invite-only, which reads as the
    // change having silently failed.
    await _resyncLocalGrids();
    ref.invalidate(sessionProvider);
    state = const ChangeGridTypeIdle();
    return null;
  }

  /// `grid sync` re-fetches the grid list + per-grid tokens from the saved
  /// session, so the local record matches what the control plane now says.
  ///
  /// Best-effort: the change itself already succeeded, so a sync failure is not
  /// a failed change — reporting it as one would tell the owner to retry
  /// something that is already done. An expired session goes to the app's own
  /// banner, which is the one thing they must act on.
  Future<void> _resyncLocalGrids() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) return;
    final sync = await service.run(['sync']);
    if (sync.sessionExpired) {
      await ref.read(sessionExpiryProvider.notifier).onExpired();
    }
  }
}

final changeGridTypeControllerProvider =
    NotifierProvider<ChangeGridTypeController, ChangeGridTypeState>(
      ChangeGridTypeController.new,
    );
