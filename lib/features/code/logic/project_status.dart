import 'code_task.dart';
import 'wire.dart';

/// The task holding this member's one slot, as `grid project status` reports it.
class SlotHolder {
  const SlotHolder({required this.id, required this.state, this.createdAt});

  final String id;
  final TaskState state;
  final DateTime? createdAt;

  static SlotHolder? fromJson(Map<String, dynamic> json) {
    final id = wireString(json, 'id');
    if (id == null) return null;
    return SlotHolder(
      id: id,
      state: TaskState.fromWire(wireString(json, 'state')),
      createdAt: wireTime(json, 'created_at'),
    );
  }
}

/// How much of the project's work is waiting, and how much is moving.
class ProjectQueue {
  const ProjectQueue({this.queued = 0, this.running = 0, this.oldestQueuedAt});

  final int queued;
  final int running;
  final DateTime? oldestQueuedAt;

  bool get isBusy => queued > 0 || running > 0;

  static ProjectQueue fromJson(Map<String, dynamic> json) => ProjectQueue(
    queued: wireInt(json, 'queued') ?? 0,
    running: wireInt(json, 'running') ?? 0,
    oldestQueuedAt: wireTime(json, 'oldest_queued_at'),
  );
}

/// Who could take the work — the relay's own view of the fleet behind a grid.
class ProviderFleet {
  const ProviderFleet({
    this.servesYou,
    this.online,
    this.paused,
    this.resumesAt,
  });

  /// Whether this grid serves the caller's email domain.
  ///
  /// **Absent means yes**: a relay predating the allowlist, and every relay
  /// with none configured, say nothing here. Reading absence as a refusal
  /// would invent one. Only an explicit `false` means no provider will ever
  /// claim this member's work.
  final bool? servesYou;

  final int? online;
  final int? paused;

  /// When the first withdrawn provider starts claiming again. The actionable
  /// half: "paused" alone tells a team to keep watching, a time tells them
  /// whether to wait or to add a machine.
  final DateTime? resumesAt;

  /// The fleet is readable enough to say something about. A block with an
  /// unusable count is not a fleet report, and saying nothing beats "2 of null
  /// providers have withdrawn".
  bool get isReadable => online != null && paused != null;

  static ProviderFleet fromJson(Map<String, dynamic> json) => ProviderFleet(
    servesYou: wireBool(json, 'serves_you'),
    online: wireInt(json, 'online'),
    paused: wireInt(json, 'paused'),
    resumesAt: wireTime(json, 'resumes_at'),
  );
}

/// Where a project is, from this member's side.
///
/// Also the change signal: [mainCommit] moves on a promote or an import, and
/// [wipCommit] moves when a task settles, when a clean integration lands, or on
/// a commit — so the app watches this instead of polling git. A *conflicting*
/// integration moves no ref at all and shows up as [slotHolder] instead, which
/// is why both are read.
class ProjectStatus {
  const ProjectStatus({
    required this.projectId,
    required this.branch,
    required this.trunk,
    this.memberKey,
    this.mainCommit,
    this.wipCommit,
    this.ahead,
    this.behind,
    this.canPromote,
    this.slotHolder,
    this.queue = const ProjectQueue(),
    this.fleet = const ProviderFleet(),
  });

  final String projectId;

  /// This member's own branch — `wip/<member_key>`, written by the grid alone.
  final String branch;

  /// The release branch, almost always `main`. Only an import and a promote
  /// ever move it.
  final String trunk;

  final String? memberKey;
  final String? mainCommit;
  final String? wipCommit;

  /// How far this member's branch is from the trunk.
  ///
  /// **Null is not zero.** `0/0` reads as "up to date", and the next thing
  /// somebody does on that belief is promote a branch that does not exist yet.
  final int? ahead;
  final int? behind;

  /// Whether a promote would be accepted — the relay's own answer, kept rather
  /// than re-derived from `behind == 0`. Deriving it here would put the rule in
  /// a second place, free to disagree about a fact only the relay can see.
  /// Null means the relay didn't say.
  final bool? canPromote;

  /// The task holding this member's one slot, if any. Without it there is
  /// nothing to wait on, read, or cancel.
  final SlotHolder? slotHolder;

  final ProjectQueue queue;
  final ProviderFleet fleet;

  /// Nothing has ever landed on this member's branch, so there is no distance
  /// to report and nothing to promote.
  bool get hasNothingYet => ahead == null || behind == null;

  /// The project has no trunk: nobody has imported a repository into it, and a
  /// task cannot be created until somebody does.
  bool get needsImport => mainCommit == null;

  /// A reply with no `branch` is not a status — the rule every handler in this
  /// plane follows. Rendering the template with blanks reads as "you have no
  /// work", which is the one answer nobody should get from a mangled body.
  static bool isReadable(Map<String, dynamic> json) =>
      wireString(json, 'branch') != null;

  static ProjectStatus? fromJson(Map<String, dynamic> json) {
    final branch = wireString(json, 'branch');
    final projectId = wireString(json, 'project_id');
    if (branch == null || projectId == null) return null;
    return ProjectStatus(
      projectId: projectId,
      branch: branch,
      trunk: wireString(json, 'trunk') ?? 'main',
      memberKey: wireString(json, 'member_key'),
      mainCommit: wireString(json, 'main_commit'),
      wipCommit: wireString(json, 'wip_commit'),
      ahead: wireInt(json, 'ahead'),
      behind: wireInt(json, 'behind'),
      canPromote: wireBool(json, 'can_promote'),
      slotHolder: SlotHolder.fromJson(wireMap(json, 'active_task')),
      queue: ProjectQueue.fromJson(wireMap(json, 'queue')),
      fleet: ProviderFleet.fromJson(wireMap(json, 'providers')),
    );
  }
}

/// How far this member's work is from the team's, in a sentence.
///
/// Absent counts are said as "nothing to compare", never as `0 / 0` — that
/// reads as up to date, and the next thing somebody does on that belief is
/// publish a branch that does not exist.
String distanceSummary(ProjectStatus status) {
  final ahead = status.ahead;
  final behind = status.behind;
  if (ahead == null || behind == null) {
    return 'Nothing of yours here yet — ask for something below.';
  }
  if (ahead == 0 && behind == 0) return 'Your copy matches the team’s.';
  final parts = [
    if (ahead > 0) '$ahead of yours not shared yet',
    if (behind > 0) '$behind from the team you don’t have',
  ];
  return parts.join(' · ');
}

/// Why the project's work isn't moving, in one sentence — or null when nothing
/// is wrong.
///
/// Silence is the point. A line reading "0 paused" on every poll is the kind of
/// noise that makes the one that matters invisible.
String? fleetNotice(ProjectStatus status) {
  final fleet = status.fleet;
  // A fact about the *caller*, not about the queue: it does not become true
  // when work starts waiting and it does not stop being true when the waiting
  // ends. So it is said whether or not anything is queued — the state a member
  // is in right after a task expires unclaimed is exactly an empty queue.
  if (fleet.servesYou == false) {
    return 'This grid does not serve your email domain, so no computer here '
        'will pick up your work. Ask whoever runs the grid to add it.';
  }
  if (!status.queue.isBusy || !fleet.isReadable) return null;
  if (fleet.online == 0) {
    return 'No computer is online for this grid, so nothing here can start. '
        'Someone on the team needs to share theirs.';
  }
  final paused = fleet.paused ?? 0;
  if (paused == 0) return null;
  final resumes = fleet.resumesAt;
  final when = resumes == null
      ? ''
      : ' The first starts again around '
            '${resumes.hour.toString().padLeft(2, '0')}:'
            '${resumes.minute.toString().padLeft(2, '0')}.';
  return '$paused of ${fleet.online} computers have stepped back — their '
      'Claude subscription is out of headroom, so they are not taking work.'
      '$when';
}
