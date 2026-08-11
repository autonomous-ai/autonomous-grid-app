/// What Sync & Backup is doing, as one value the screen switches on.
///
/// A sealed family rather than a handful of booleans: "uploading" and "failed"
/// and "asking for a password" are mutually exclusive, and the compiler should
/// be the one enforcing that rather than a reviewer.
library;

/// The step an upload or download is on, in the user's terms.
enum SyncStage {
  /// Reading chats, prompts, projects and working out which media travels.
  gathering,

  /// Locking it — the Argon2id pass plus the encryption.
  sealing,

  /// Sending the pictures that aren't on the server yet.
  uploadingMedia,

  /// Sending the backup itself.
  uploadingSnapshot,

  /// Fetching the backup.
  downloading,

  /// Fetching the pictures it references.
  downloadingMedia,

  /// Backing up what's here, then folding the two together.
  merging,
}

sealed class SyncRunState {
  const SyncRunState();
}

/// Nothing in flight.
class SyncIdle extends SyncRunState {
  const SyncIdle();
}

/// A transfer is running.
///
/// [done] / [total] are only meaningful for the media stages, where the count is
/// the honest unit of progress — one file at a time. Elsewhere they are zero and
/// the screen shows the stage alone rather than a bar that doesn't move.
class SyncBusy extends SyncRunState {
  const SyncBusy(this.stage, {this.done = 0, this.total = 0});

  final SyncStage stage;
  final int done;
  final int total;

  bool get hasCount => total > 0;
}

/// It worked, with a line naming what actually changed.
class SyncSucceeded extends SyncRunState {
  const SyncSucceeded(this.message);

  final String message;
}

/// It didn't. [message] is for the screen; the raw cause is already in the log.
class SyncFailed extends SyncRunState {
  const SyncFailed(this.message);

  final String message;
}

/// What a finished download did, so the screen can say it plainly instead of
/// "done".
typedef SyncMergeSummary = ({
  int added,
  int replaced,
  int keptLocal,
  int media,
});
