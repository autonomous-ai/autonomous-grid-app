import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';

/// True when the account can manage at least one grid as an engine host (owner
/// or provider) — i.e. the Engines tab is reachable somewhere and the app's
/// engine-setup guidance applies.
///
/// False for a consumer-only account (only public grids it didn't create),
/// whose first run needs a different nudge: there's no engine to set up, so the
/// path is simply "open a grid and try it".
final hasManageableGridProvider = Provider<bool>((ref) {
  return ref.watch(sessionProvider).networks.any((n) => n.canManageProvider);
});

/// Whether the first-run "getting started" coach has been dismissed this
/// session. Session-scoped on purpose: it's a lightweight nudge, not a saved
/// setting — and it stops for good once the user gains a manageable grid (see
/// [showGettingStartedProvider]).
final gettingStartedDismissedProvider =
    NotifierProvider<GettingStartedDismissed, bool>(
      GettingStartedDismissed.new,
    );

class GettingStartedDismissed extends Notifier<bool> {
  @override
  bool build() => false;

  void dismiss() => state = true;
}

/// Show the first-run coach only for a consumer-only account (has grids, none
/// manageable) that hasn't dismissed it this session. An owner/provider already
/// has the Engines tab and its own setup flow, so they're never nagged.
final showGettingStartedProvider = Provider<bool>((ref) {
  if (ref.watch(sessionProvider).networks.isEmpty) return false;
  if (ref.watch(hasManageableGridProvider)) return false;
  return !ref.watch(gettingStartedDismissedProvider);
});
