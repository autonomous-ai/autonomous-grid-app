import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import 'session_controller.dart';

/// Where the saved session stands after a `grid` command reported it invalid.
enum SessionExpiry {
  /// Normal — nothing to recover.
  healthy,

  /// Trying `grid auth refresh` to renew the network token without bothering
  /// the user.
  refreshing,

  /// Refresh wasn't possible or failed — a full `grid auth login` is required.
  needsLogin,
}

/// Tracks recovery from an expired/invalid session and drives the app-wide
/// banner. Shared so any sync site can hand off the problem and any surface can
/// react, without threading the signal through every controller.
final sessionExpiryProvider =
    NotifierProvider<SessionExpiryController, SessionExpiry>(
  SessionExpiryController.new,
);

class SessionExpiryController extends Notifier<SessionExpiry> {
  @override
  SessionExpiry build() => SessionExpiry.healthy;

  /// A command saw an expired/invalid session. `grid sync` fails on a dead
  /// *session* token, but each network keeps its own *refresh* token — so try
  /// `grid auth refresh` for the active network first. Only a dead refresh
  /// token forces a full re-login.
  Future<void> onExpired() async {
    if (state == SessionExpiry.refreshing) return; // dedupe concurrent triggers
    state = SessionExpiry.refreshing;

    final networkId = ref.read(sessionProvider).active?.networkId;
    final service = ref.read(gridCliServiceProvider);
    if (networkId == null || service == null) {
      state = SessionExpiry.needsLogin;
      return;
    }

    final apiUrl = ref.read(gridApiUrlProvider);
    final result = await service.run([
      'auth', 'refresh', '--network', networkId,
      if (apiUrl.isNotEmpty) ...['--api-url', apiUrl],
    ]);

    if (result.ok) {
      ref.invalidate(sessionProvider); // re-read the freshly written token
      state = SessionExpiry.healthy;
      return;
    }
    state = SessionExpiry.needsLogin;
  }

  /// Reset once the user acts on it (signs out to re-authenticate).
  void reset() => state = SessionExpiry.healthy;
}
