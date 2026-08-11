import 'code_task.dart';
import 'wire.dart';

/// What `grid project import` did — the one way a project gets a trunk.
///
/// A refused import leaves the project with **no trunk on purpose**: half a
/// trunk would be worse, because the trunk is the one ref nothing in this
/// design rewrites. So [fromJson] returns null unless the relay said the
/// repository was imported.
class ImportResult {
  const ImportResult({
    required this.commit,
    required this.trunk,
    this.warnings = const [],
  });

  final String commit;
  final String trunk;

  /// The relay's own words about a repository this app never read. Shown
  /// verbatim: the only one today (Git LFS) is a fact about what an agent will
  /// find on disk, not an error.
  final List<String> warnings;

  static ImportResult? fromJson(Map<String, dynamic> json) {
    final commit = wireString(json, 'commit');
    if (wireString(json, 'status') != 'imported' || commit == null) return null;
    return ImportResult(
      commit: commit,
      trunk: wireString(json, 'trunk') ?? 'main',
      warnings: wireStrings(json, 'warnings'),
    );
  }
}

/// What `grid project commit` wrote — files landed on the member's branch with
/// no agent involved.
class CommitResult {
  const CommitResult({
    required this.commit,
    required this.branch,
    this.previousCommit,
    this.files = const [],
    this.deletes = const [],
  });

  final String commit;
  final String branch;
  final String? previousCommit;
  final List<String> files;
  final List<String> deletes;

  static CommitResult? fromJson(Map<String, dynamic> json) {
    final commit = wireString(json, 'commit');
    if (commit == null) return null;
    return CommitResult(
      commit: commit,
      branch: wireString(json, 'branch') ?? 'your branch',
      previousCommit: wireString(json, 'previous_commit'),
      files: wireStrings(json, 'files'),
      deletes: wireStrings(json, 'deletes'),
    );
  }
}

/// Where `grid project clone` put a working copy, and on which branch.
class CloneResult {
  const CloneResult({
    required this.path,
    required this.branch,
    required this.trunk,
    this.startedFromTrunk = false,
  });

  final String path;
  final String branch;
  final String trunk;

  /// This member's branch has nothing on it yet, so the clone starts at the
  /// trunk. Worth saying: until their first task lands, the clone otherwise
  /// looks like somebody else's repository.
  final bool startedFromTrunk;

  static CloneResult? fromJson(Map<String, dynamic> json) {
    final path = wireString(json, 'path');
    final branch = wireString(json, 'branch');
    if (path == null || branch == null) return null;
    return CloneResult(
      path: path,
      branch: branch,
      trunk: wireString(json, 'trunk') ?? 'main',
      startedFromTrunk: wireBool(json, 'started_from_trunk') ?? false,
    );
  }
}

/// Where `grid task fetch` put one task's result.
class FetchResult {
  const FetchResult({
    required this.path,
    required this.state,
    this.resultCommit,
    this.branch,
  });

  final String path;
  final TaskState state;

  /// Absent means the branch holds only what the task started from — a
  /// cancelled run that never wrote anything. Said out loud, because a folder
  /// of the task's own input files reads as a result.
  final String? resultCommit;

  final String? branch;

  bool get isInputOnly => resultCommit == null;

  static FetchResult? fromJson(Map<String, dynamic> json) {
    final path = wireString(json, 'path');
    if (path == null) return null;
    return FetchResult(
      path: path,
      state: TaskState.fromWire(wireString(json, 'state')),
      resultCommit: wireString(json, 'result_commit'),
      branch: wireString(json, 'branch'),
    );
  }
}

/// What `grid task cancel` left behind.
///
/// The slot is free immediately; the agent itself stops within about half a
/// minute, on the provider's next lease renewal. Nothing is rewound.
class CancelResult {
  const CancelResult({required this.state, this.error});

  final TaskState state;

  /// Why it ended. Kept beside the state because `failed` on its own reads as
  /// "the agent broke", which is the one thing that did not happen here.
  final String? error;

  static CancelResult? fromJson(Map<String, dynamic> json) {
    final state = wireString(json, 'state');
    // A reply that does not say what state the task is now in is not a
    // cancellation. Reporting one would tell somebody their colleague's
    // hour-long merge task had stopped while it ran on.
    if (state == null) return null;
    return CancelResult(
      state: TaskState.fromWire(state),
      error: wireString(json, 'error'),
    );
  }
}
