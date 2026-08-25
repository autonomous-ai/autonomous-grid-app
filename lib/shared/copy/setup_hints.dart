/// The sentences that send a user to the screen where this computer is set up.
///
/// One file, because the screen keeps moving and the copy keeps being left
/// behind: it was four loose entries in the account menu, then Settings ▸ This
/// computer, then a row in the sidebar, and it is now a button on the top bar.
/// Each move rewrote a dozen error messages by hand, and the ones that were
/// missed named a place that no longer existed — the exact failure §5 calls out.
/// Name it here, use it everywhere.
library;

/// Where a user goes to make this computer serve a model — the button's own
/// words, so the sentence and the thing it points at agree.
const kModelEnginesPlace = 'Model engines in the top bar';

/// "This computer isn't set up to `activity` yet…", with the way to fix it.
///
/// [activity] completes the first clause — "answer chats", "run tasks", "run the
/// assistant". The wording is one sentence of fact and one of next step, which
/// is what makes it usable wherever an agent, a task or a connector finds this
/// machine has no engine behind it.
String notSetUpToMessage(String activity) =>
    "This computer isn't set up to $activity yet. Open $kModelEnginesPlace to "
    'finish setting it up.';
