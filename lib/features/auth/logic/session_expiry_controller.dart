import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import 'session_controller.dart';

/// Where the saved session stands after a `grid` command reported it invalid.
enum SessionExpiry {
  /// Normal — nothing to recover.
  healthy,

  /// Trying `grid sync` to renew the grid tokens from the saved session without
  /// bothering the user.
  refreshing,

  /// Refresh wasn't possible or failed — a full `grid login` is required.
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

  /// A command saw an expired/invalid session. Try `grid sync` first — it reuses
  /// the saved session token to re-fetch every grid's access token without a
  /// browser, recovering silently when only the per-grid tokens lapsed. Only a
  /// dead *session* token (sync fails) forces a full re-login.
  Future<void> onExpired() async {
    if (state == SessionExpiry.refreshing) return; // dedupe concurrent triggers
    state = SessionExpiry.refreshing;

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = SessionExpiry.needsLogin;
      return;
    }

    final result = await service.run(['sync']);
    if (result.ok) {
      ref.invalidate(sessionProvider); // re-read the freshly written tokens
      state = SessionExpiry.healthy;
      return;
    }
    state = SessionExpiry.needsLogin;
  }

  /// Reset once the user acts on it (signs out to re-authenticate).
  void reset() => state = SessionExpiry.healthy;
}
