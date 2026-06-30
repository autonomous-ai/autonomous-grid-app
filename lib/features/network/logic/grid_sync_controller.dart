import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import '../../auth/logic/session_expiry_controller.dart';

/// Where a manual `grid sync` stands. Drives the sidebar sync button — spinner
/// while running, a one-shot toast on done/failed. Modelled as a sealed state so
/// the button switches exhaustively instead of juggling booleans.
sealed class GridSyncState {
  const GridSyncState();
}

/// Nothing in flight — the resting state and the start of every sync.
class GridSyncIdle extends GridSyncState {
  const GridSyncIdle();
}

/// `grid sync` is running; the button shows a spinner and ignores taps.
class GridSyncRunning extends GridSyncState {
  const GridSyncRunning();
}

/// The grid list was refreshed from the cloud.
class GridSyncDone extends GridSyncState {
  const GridSyncDone();
}

/// Sync failed; [message] is a user-friendly line (raw detail stays in Debug).
class GridSyncFailed extends GridSyncState {
  const GridSyncFailed(this.message);
  final String message;
}

final gridSyncControllerProvider =
    NotifierProvider<GridSyncController, GridSyncState>(GridSyncController.new);

/// Manual counterpart to the automatic `grid sync` that runs after create/login:
/// re-fetches the grid list + per-grid tokens from the saved session (no
/// browser) and refreshes the sidebar. An expired session is handed off to the
/// app-wide banner ([sessionExpiryProvider]) instead of failing here.
class GridSyncController extends Notifier<GridSyncState> {
  @override
  GridSyncState build() => const GridSyncIdle();

  Future<void> sync() async {
    if (state is GridSyncRunning) return; // dedupe double-taps
    state = const GridSyncRunning();

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const GridSyncFailed('The grid CLI was not found.');
      return;
    }

    final result = await service.run(['sync']);
    if (result.sessionExpired) {
      await ref.read(sessionExpiryProvider.notifier).onExpired();
      state = const GridSyncIdle();
      return;
    }
    if (!result.ok) {
      state = const GridSyncFailed("Couldn't refresh your grids. Try again.");
      return;
    }

    ref.invalidate(sessionProvider); // re-read the freshly written grid list
    state = const GridSyncDone();
  }
}
