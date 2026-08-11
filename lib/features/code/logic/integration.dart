import 'wire.dart';

/// What bringing the trunk into a member's branch does, or would do.
///
/// One vocabulary for both questions on purpose — `grid project check` answers
/// in `grid project integrate`'s own words — so a screen branches on one set of
/// four rather than mapping a preview enum onto a real one.
enum IntegrationStatus {
  /// The branch already has everything on the trunk.
  upToDate('up_to_date'),

  /// The branch moves straight onto the trunk. No merge commit, nothing to
  /// review.
  fastForward('fast_forward'),

  /// A real merge, leaving a merge commit on the branch.
  merged('merged'),

  /// Both sides changed the same lines, so an **agent** is queued to resolve
  /// it. That costs a run and holds the member's one task slot, and nothing has
  /// moved when the command returns.
  mergeTask('merge_task'),

  /// A word this build does not know. Never rendered as an outcome: a status
  /// nobody can read is not an integration that happened.
  unknown('');

  const IntegrationStatus(this.wire);

  final String wire;

  static IntegrationStatus fromWire(String? value) {
    for (final status in values) {
      if (status.wire == value && status != unknown) return status;
    }
    return unknown;
  }
}

/// What `grid project check` says integrating **would** do. A pure read: it
/// moves no ref, queues no agent and holds no slot.
class IntegrationPreview {
  const IntegrationPreview({
    required this.status,
    required this.branch,
    this.ahead,
    this.behind,
    this.files = const [],
  });

  final IntegrationStatus status;
  final String branch;
  final int? ahead;
  final int? behind;

  /// The paths a conflict would touch. Sent as data precisely so this does not
  /// have to be dug out of a sentence.
  final List<String> files;

  /// Whether integrating would cost an agent run.
  bool get wouldQueueAgent => status == IntegrationStatus.mergeTask;

  static IntegrationPreview? fromJson(Map<String, dynamic> json) {
    final status = IntegrationStatus.fromWire(wireString(json, 'status'));
    if (status == IntegrationStatus.unknown) return null;
    return IntegrationPreview(
      status: status,
      branch: wireString(json, 'branch') ?? 'your branch',
      ahead: wireInt(json, 'ahead'),
      behind: wireInt(json, 'behind'),
      files: wireStrings(json, 'files'),
    );
  }
}

/// What `grid project integrate` actually did.
///
/// [fromJson] returns null for a reply this app cannot read, and that check is
/// the point of the class: reporting a success by default is how a body a proxy
/// had stripped once told a team their work had landed — and the next thing
/// somebody does on that belief is promote.
class IntegrationResult {
  const IntegrationResult({
    required this.status,
    required this.branch,
    this.commit,
    this.previousCommit,
    this.taskId,
    this.memberKey,
    this.files = const [],
  });

  final IntegrationStatus status;
  final String branch;
  final String? commit;
  final String? previousCommit;

  /// The merge task an agent is about to run, on a conflicting integration.
  /// The whole payload of that outcome, so a reply without it leaves nothing to
  /// watch or wait on.
  final String? taskId;

  final String? memberKey;
  final List<String> files;

  static IntegrationResult? fromJson(Map<String, dynamic> json) {
    final status = IntegrationStatus.fromWire(wireString(json, 'status'));
    if (status == IntegrationStatus.unknown) return null;
    final commit = wireString(json, 'commit');
    final taskId = wireString(json, 'task_id');
    final needsCommit =
        status == IntegrationStatus.fastForward ||
        status == IntegrationStatus.merged;
    if (needsCommit && commit == null) return null;
    if (status == IntegrationStatus.mergeTask && taskId == null) return null;
    return IntegrationResult(
      status: status,
      branch: wireString(json, 'branch') ?? 'your branch',
      commit: commit,
      previousCommit: wireString(json, 'previous_commit'),
      taskId: taskId,
      memberKey: wireString(json, 'member_key'),
      files: wireStrings(json, 'files'),
    );
  }
}

/// What `grid project promote` did to the trunk.
///
/// **There is no revert in this release**, so [previousCommit] is the only
/// record of the release this one replaced — `grid project wip reset` is what
/// takes it, and somebody undoing a promote needs it.
class PromoteResult {
  const PromoteResult({
    required this.branch,
    required this.advanced,
    this.commit,
    this.previousCommit,
    this.recorded = true,
  });

  /// The ref that moved — the trunk, not the member's branch.
  final String branch;

  /// Whether the trunk actually moved. `false` is a real answer: the trunk was
  /// already there, and saying "released" for a no-op tells a team something
  /// shipped when nothing did.
  final bool advanced;

  final String? commit;
  final String? previousCommit;

  /// Whether the relay recorded who released this. The trunk moved either way,
  /// so a missing row is a warning rather than a failure — but left unsaid it
  /// is discoverable only as a hole in the project's release history.
  final bool recorded;

  static PromoteResult? fromJson(Map<String, dynamic> json) {
    final advanced = wireBool(json, 'advanced');
    final commit = wireString(json, 'commit');
    // Tri-state, like `can_promote`: anything that is not one of the two
    // answers is a reply this app cannot read, not a release.
    if (advanced == null) return null;
    if (advanced && commit == null) return null;
    return PromoteResult(
      branch: wireString(json, 'branch') ?? 'main',
      advanced: advanced,
      commit: commit,
      previousCommit: wireString(json, 'previous_commit'),
      recorded: json['promotion_id'] != null,
    );
  }
}
