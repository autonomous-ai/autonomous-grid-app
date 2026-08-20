import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/credentials_file.dart';
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

/// A way past the question for this run of the app, and no further.
///
/// The screen is a fork, not a wall (§5). Without this it is a wall for exactly
/// the user it can't help: someone with no grids yet, on the day the control
/// plane is unreachable, would have no answer available and no way into an app
/// they could otherwise still open. They land on [NoGridNotice] instead, which
/// says what's missing and leads back here.
///
/// Session-only on purpose — it is not an answer, so it must not be remembered
/// as one. The question comes back next launch, and by then it is usually one
/// click.
final gridChoiceSkippedProvider = NotifierProvider<GridChoiceSkipped, bool>(
  GridChoiceSkipped.new,
);

class GridChoiceSkipped extends Notifier<bool> {
  @override
  bool build() => false;

  void skip() => state = true;
}

/// The live answer, wiring the app's providers into [needsGridChoice].
final gridChoiceNeededProvider = Provider<bool>((ref) {
  if (ref.watch(gridChoiceSkippedProvider)) return false;
  return needsGridChoice(
    credentials: ref.watch(sessionProvider),
    chosenGridId: ref.watch(chatPrefsProvider.select((p) => p.networkId)),
  );
});
