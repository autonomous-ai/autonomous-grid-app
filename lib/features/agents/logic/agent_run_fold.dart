import 'dart:math' as math;

/// How long a run of steps may get before a saved turn stops drawing all of it.
///
/// **This is a freeze, not a preference.** Every step in a turn is drawn as its
/// own stateful row — hover, chevron, and a painted segment of the guide line —
/// and a run draws them in one `Column`, in one frame. An agent left working
/// through a `/loop` overnight produces runs nothing here anticipated: measured
/// on one machine, a single chat held 7,765 steps with **2,662 of them in one
/// message**. Opening that chat built 2,662 rows at once and the window stopped
/// answering for seconds. Twelve is about two screenfuls of run; past that a
/// person is scrolling rather than reading.
const int kFoldedRun = 12;

/// What a folded run still shows: the tail, because the steps a turn ended on
/// are the ones the answer above them came out of.
const int kFoldedRunTail = 8;

/// The ceiling on opening one, for the same reason [kFoldedRun] exists — asking
/// to see more is not asking for the window to stop responding. The whole run
/// stays in the transcript on disk either way.
const int kOpenedRunLimit = 200;

/// Whether a run of [total] steps is drawn whole, or folded to its tail.
bool runIsFolded(int total) => total > kFoldedRun;

/// How many of a run's steps are on screen — the last this many.
///
/// Pure, because it is the policy rather than the drawing: what is folded, what
/// opening one gives you, and the ceiling that keeps "show me more" from being
/// the same freeze in a costume.
int visibleRunSteps(int total, {required bool open}) {
  if (!runIsFolded(total)) return total;
  return open ? math.min(total, kOpenedRunLimit) : kFoldedRunTail;
}
