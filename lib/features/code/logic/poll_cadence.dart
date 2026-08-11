/// How often the Code screens re-read the grid, and why there are two answers.
///
/// A task outlives the request that created it, so nothing is held open and the
/// only way to notice a change is to ask. The relay offers `project status` as
/// the change signal for exactly this — the trunk moves on a promote or an
/// import, a member's branch moves when a task settles — so the app watches it
/// instead of polling git.
///
/// Two cadences, because a project with work in flight changes minute by minute
/// and an idle one does not. Polling an idle project every few seconds is a
/// cost on somebody's relay with nothing on the other side of it.
library;

/// Something is queued or running, so the answer can change at any moment.
const kBusyPoll = Duration(seconds: 6);

/// Nothing is in flight. Slow enough to be free, quick enough that a colleague
/// promoting shows up while the user is still looking at the screen.
const kIdlePoll = Duration(seconds: 30);
