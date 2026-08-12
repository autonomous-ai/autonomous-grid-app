import 'wire.dart';

/// Where a task has got to.
///
/// [unknown] is a state this build has never heard of, and it is deliberately
/// **not** terminal — the same conservative reading the CLI takes. A newer
/// relay's extra state must leave the result unfetchable rather than hand back
/// the task's input files as though they were what the agent produced.
enum TaskState {
  queued('queued', 'Waiting for a computer'),
  running('running', 'Working'),
  completed('completed', 'Done'),
  failed('failed', 'Failed'),
  timedOut('timed_out', 'Ran out of time'),
  unknown('', 'Unknown');

  const TaskState(this.wire, this.label);

  /// The relay's own word for it.
  final String wire;

  /// What the screen says. Plain language: nobody outside this codebase knows
  /// what `timed_out` means, and "Queued" reads as jargon beside it.
  final String label;

  /// The task has stopped and its branch is final.
  bool get isTerminal =>
      this == completed || this == failed || this == timedOut;

  /// Still going, so it holds this member's one task slot.
  bool get isActive => this == queued || this == running;

  static TaskState fromWire(String? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return unknown;
  }
}

/// The terminal reason meaning no provider ever claimed the task.
///
/// It is one word from `deadline_exceeded` and calls for the opposite action —
/// add providers, rather than fix the task — which is why it is the one reason
/// the UI reads rather than prints verbatim.
const kQueueExpired = 'queue_expired';

/// One agent run against a project, as the relay reports it.
///
/// Every field beyond [id] is optional: `grid task list` sends a summary and
/// `grid task get` sends the whole row, and both are parsed here so a list row
/// and an open task are never two different shapes.
class CodeTask {
  const CodeTask({
    required this.id,
    required this.state,
    this.projectId,
    this.prompt,
    this.memberKey,
    this.providerId,
    this.error,
    this.resultText,
    this.resultCommit,
    this.baseCommit,
    this.branch,
    this.branchPruned = false,
    this.createdAt,
    this.attempt,
    this.maxAttempts,
  });

  final String id;
  final TaskState state;
  final String? projectId;

  /// What was asked for. Up to 100 KB, so a list row shows the first line of it
  /// and the open task shows the whole thing.
  final String? prompt;

  /// Who submitted it. Absent when they have since left the project.
  final String? memberKey;

  /// The machine that claimed it, once one has.
  final String? providerId;

  /// Why it ended, when it ended badly. The relay's own slug, kept raw here and
  /// humanized at the edge — see [queueExpired].
  final String? error;

  /// The agent's closing words, on a task that finished.
  final String? resultText;

  /// The commit the agent left behind. Absent on a task that was cancelled
  /// before it wrote anything, whose branch still holds the input.
  final String? resultCommit;

  /// The commit the task was cut from — what `grid project wip reset` takes to
  /// undo a settle that landed work nobody wanted.
  final String? baseCommit;

  final String? branch;

  /// The relay no longer keeps this task's branch: its files were collected
  /// after the project's retention window, so fetching would fail with git's
  /// own "couldn't find remote ref", which reads as corruption.
  final bool branchPruned;

  final DateTime? createdAt;

  /// Which try this is. A task whose provider died goes back on the queue, so
  /// an attempt past the first is ordinary rather than a fault.
  final int? attempt;
  final int? maxAttempts;

  /// It ran out of time *waiting for a provider* rather than while running —
  /// the grid is short of capacity, and the task itself is not at fault.
  bool get queueExpired => error == kQueueExpired;

  /// There is something on the relay to fetch. A cancelled task qualifies: its
  /// branch is left where the agent got to, which is the promise `cancel`
  /// makes on screen.
  bool get hasFetchableBranch =>
      state.isTerminal && branch != null && !branchPruned;

  /// The first line of the prompt, for a list row. Whitespace is collapsed the
  /// way the CLI's own table does it — a prompt pasted from an editor arrives
  /// full of newlines and would otherwise make one row as tall as the list.
  String get summary {
    final text = prompt?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (text == null || text.isEmpty) ? 'Untitled task' : text;
  }

  /// What was asked, as it was written — paragraphs and all.
  ///
  /// [summary] flattens it for a one-line row; the transcript shows a request
  /// the way its author typed it, since a task prompt runs to paragraphs far
  /// more often than a chat message does.
  String get asked {
    final text = prompt?.trimRight();
    return (text == null || text.trim().isEmpty) ? summary : text;
  }

  static CodeTask? fromJson(Map<String, dynamic> json) {
    final id = wireString(json, 'id');
    if (id == null) return null;
    return CodeTask(
      id: id,
      state: TaskState.fromWire(wireString(json, 'state')),
      projectId: wireString(json, 'project_id'),
      prompt: wireString(json, 'prompt'),
      memberKey: wireString(json, 'member_key'),
      providerId: wireString(json, 'provider_id'),
      error: wireString(json, 'error'),
      resultText: wireString(json, 'result_text'),
      resultCommit: wireString(json, 'result_commit'),
      baseCommit: wireString(json, 'base_commit'),
      branch: wireString(json, 'branch'),
      // Absent means "still there": a relay predating branch collection sends
      // no such key, and reading absence the other way would refuse every
      // fetch against every relay that has not redeployed.
      branchPruned: wireBool(json, 'branch_pruned') ?? false,
      createdAt: wireTime(json, 'created_at'),
      attempt: wireInt(json, 'attempt'),
      maxAttempts: wireInt(json, 'max_attempts'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CodeTask &&
      other.id == id &&
      other.state == state &&
      other.projectId == projectId &&
      other.prompt == prompt &&
      other.memberKey == memberKey &&
      other.providerId == providerId &&
      other.error == error &&
      other.resultText == resultText &&
      other.resultCommit == resultCommit &&
      other.baseCommit == baseCommit &&
      other.branch == branch &&
      other.branchPruned == branchPruned &&
      other.createdAt == createdAt &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts;

  @override
  int get hashCode => Object.hash(
    id,
    state,
    projectId,
    prompt,
    memberKey,
    providerId,
    error,
    resultText,
    resultCommit,
    baseCommit,
    branch,
    branchPruned,
    createdAt,
    Object.hash(attempt, maxAttempts),
  );
}

/// One page of `grid task list --json`.
///
/// [nextAfter] is said out loud on screen for the reason the CLI prints it: a
/// page that silently stops at the limit reads as the project's whole history.
class TaskPage {
  const TaskPage({required this.tasks, this.nextAfter});

  final List<CodeTask> tasks;
  final String? nextAfter;

  /// Whether the reply carried a task list at all.
  ///
  /// Checked on **presence**, not truthiness: an empty list is a real answer,
  /// and a body a proxy had stripped came back as `{}` and told somebody
  /// polling a shared project that nobody was working.
  static bool carriesTasks(Map<String, dynamic> json) => json['tasks'] is List;

  static TaskPage fromJson(Map<String, dynamic> json) => TaskPage(
    tasks: [
      for (final entry in wireObjects(json, 'tasks')) ?CodeTask.fromJson(entry),
    ],
    nextAfter: wireString(json, 'next_after'),
  );
}
