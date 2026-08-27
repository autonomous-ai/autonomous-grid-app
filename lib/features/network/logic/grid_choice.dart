import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../auth/logic/session_controller.dart';

/// Whether the app has to stop and ask which grid the user wants before it lets
/// them in.
///
/// A grid is the one thing every other screen reads — the model fork asks what
/// *that* grid serves, chat sends there, engines share there — so the app used
/// to answer it silently with [CredentialsFile.active], a five-deep fallback the
/// user never saw and could only discover by noticing they were somewhere
/// unexpected. Asking once, out loud, is cheaper than that.
///
/// The record of the answer is [ChatPrefs.networkId] rather than a store of its
/// own, and deliberately: that field already *is* "the grid this user picked",
/// written by [SelectedNetwork.select] — the same call the choice screen makes.
/// A second file recording the same fact could disagree with it, and the one
/// that lost would strand the user on a grid they didn't choose.
///
/// A saved id that names no grid we still hold (they left it, or it was deleted)
/// counts as unanswered: better one question than a session pointed at a grid
/// that no longer exists.
bool needsGridChoice({
  required CredentialsFile credentials,
  required String? chosenGridId,
}) {
  if (chosenGridId == null || chosenGridId.trim().isEmpty) return true;
  return credentials.byName(chosenGridId) == null;
}

/// Whether this run of the app is already past the grid question.
///
/// **A door, not a condition the app keeps re-checking.** [needsGridChoice] can
/// turn true again mid-session — deleting the grid you're on is enough — and
/// without this the whole window would be replaced by the first-run screen
/// while the user was standing in Settings, with the "Deleted …" toast still
/// floating over it. The screen belongs to starting the app; once through, the
/// app handles a missing grid where the user actually is (see [NoGridNotice]).
///
/// It used to carry an "I'll choose later" escape too, and that is worth
/// knowing about: on a day the control plane is unreachable, an account with no
/// grids can now neither pick one nor create one, so this screen is where it
/// stops. The app is unusable without a grid either way, so the escape led into
/// a shell that could not chat — but it did let someone reach their settings
/// and their old chats, and nothing replaces that today.
/// **TODO(BE): give the outage its own way out**, an offline state that says
/// what is wrong rather than a silent wall.
final gridChoiceGateProvider = NotifierProvider<GridChoiceGate, bool>(
  GridChoiceGate.new,
);

class GridChoiceGate extends Notifier<bool> {
  @override
  bool build() {
    // Signing out shuts the door again. `grid logout` clears the grid pointer,
    // so the account signing in next genuinely has no grid — and a door left
    // open from the previous session walked them straight past the question
    // into whatever [CredentialsFile.active] happened to fall back to, which is
    // the silent five-deep guess this screen exists to replace.
    //
    // Watching the flag and not the session is the whole trick: this must stay
    // a door (see above), and a refresh that keeps the user signed in leaves
    // `isLoggedIn` untouched, so `select` doesn't rebuild and the door doesn't
    // slam mid-session. It only moves when sign-in state actually flips.
    ref.watch(sessionProvider.select((credentials) => credentials.isLoggedIn));
    return false;
  }

  /// Take [network] as the user's grid and go in — the one path that both
  /// answers the question and opens the door, so the two can't come apart in
  /// one of the places the screen offers it.
  ///
  /// [remember] decides whether the answer outlives this run. Unticked, the door
  /// still opens and the grid is still selected; only the note on disk is
  /// skipped, so the next launch asks again. Signing out clears that note either
  /// way (see `AuthController.logout`), so a remembered grid never greets the
  /// next account to use this computer.
  void choose(NetworkCredential network, {bool remember = true}) {
    ref
        .read(selectedNetworkProvider.notifier)
        .select(network, remember: remember);
    state = true;
  }
}

/// The live answer, wiring the app's providers into [needsGridChoice].
final gridChoiceNeededProvider = Provider<bool>((ref) {
  if (ref.watch(gridChoiceGateProvider)) return false;
  return needsGridChoice(
    credentials: ref.watch(sessionProvider),
    chosenGridId: ref.watch(chatPrefsProvider.select((p) => p.networkId)),
  );
});
