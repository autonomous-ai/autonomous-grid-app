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
/// It is also what makes "I'll choose later" possible, and why that is a door
/// rather than a saved answer: the screen is a fork, not a wall (§5), so
/// someone with no grids on a day the control plane is unreachable still gets
/// into an app they could otherwise open — and is asked again next launch,
/// because they never answered.
final gridChoiceGateProvider = NotifierProvider<GridChoiceGate, bool>(
  GridChoiceGate.new,
);

class GridChoiceGate extends Notifier<bool> {
  @override
  bool build() => false;

  /// Take [network] as the user's grid and go in — the one path that both
  /// answers the question and opens the door, so the two can't come apart in
  /// one of the three places the screen offers it.
  void choose(NetworkCredential network) {
    ref.read(selectedNetworkProvider.notifier).select(network);
    state = true;
  }

  /// Go in without answering. Nothing is written, so the next launch asks.
  void later() => state = true;
}

/// The live answer, wiring the app's providers into [needsGridChoice].
final gridChoiceNeededProvider = Provider<bool>((ref) {
  if (ref.watch(gridChoiceGateProvider)) return false;
  return needsGridChoice(
    credentials: ref.watch(sessionProvider),
    chosenGridId: ref.watch(chatPrefsProvider.select((p) => p.networkId)),
  );
});
