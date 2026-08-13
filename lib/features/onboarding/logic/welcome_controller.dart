import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/welcome_store.dart';

/// Whether the one-time welcome screen has already been shown.
///
/// Loaded once at start; [WelcomeController.markSeen] persists and updates it,
/// so the screen survives a restart having been seen — and is never shown twice.
final welcomeSeenProvider = NotifierProvider<WelcomeController, bool>(
  WelcomeController.new,
);

class WelcomeController extends Notifier<bool> {
  @override
  bool build() => ref.read(welcomeStoreProvider).load();

  /// Mark it shown and go in. Writing before the state flips is deliberate: the
  /// state change swaps this screen for the app, so a write that happened after
  /// it would be racing a widget tree that is already being torn down.
  void markSeen() {
    if (state) return;
    ref.read(welcomeStoreProvider).save();
    state = true;
  }
}
