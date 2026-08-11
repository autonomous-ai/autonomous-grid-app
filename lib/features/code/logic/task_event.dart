import 'dart:convert';

import 'code_task.dart';
import 'wire.dart';

/// One line of `grid task follow --json` — the live view of a task while it
/// runs.
///
/// A task is minutes of tool calls and a sentence of prose, so the stream is
/// mostly [TaskToolUse]. Every event carries its [seq], and the cursor is the
/// whole point: a stream that dies is resumed at the last seq seen and the
/// relay replays exactly what follows — no gap, no repeat.
sealed class TaskEvent {
  const TaskEvent(this.seq);

  final int seq;
}

/// The agent's prose — what it says about what it is doing.
class TaskOutput extends TaskEvent {
  const TaskOutput(super.seq, this.text);
  final String text;
}

/// The agent reached for a tool. [path] is absent for the ones that target
/// nothing (a shell command, a web search).
class TaskToolUse extends TaskEvent {
  const TaskToolUse(super.seq, {required this.tool, this.path});
  final String tool;
  final String? path;
}

/// A tool call came back. One arrives for **every** call and a real task makes
/// hundreds, so only [isError] is worth a line — the call's identity was
/// already announced by its [TaskToolUse].
class TaskToolResult extends TaskEvent {
  const TaskToolResult(super.seq, {required this.isError, this.callId});
  final bool isError;
  final String? callId;
}

/// The agent's own diagnostics, kept apart from its answer.
class TaskDiagnostic extends TaskEvent {
  const TaskDiagnostic(super.seq, this.text);
  final String text;
}

/// A snapshot of the task's working directory.
///
/// The provider re-sends the **whole** tree every time, because a viewer can
/// attach at any point and a retry can move the task to a machine that never
/// saw the earlier events. Between claim and terminal this is the only live
/// view there is: the provider commits at terminal boundaries only.
class TaskTree extends TaskEvent {
  const TaskTree(
    super.seq, {
    required this.paths,
    this.total,
    this.truncated = false,
    this.complete = false,
  });

  final List<String> paths;
  final int? total;
  final bool truncated;

  /// Everything the tree holds is in this event, and that can be proved.
  ///
  /// Only a complete snapshot may be compared with the one before it. A path
  /// missing from a partial snapshot is a path we were not given — reporting
  /// it as removed would be a confident, wrong claim that the agent deleted
  /// the user's file.
  final bool complete;
}

/// The agent's session id, new or resumed.
class TaskSession extends TaskEvent {
  const TaskSession(super.seq, {this.sessionId, this.resumed = false});
  final String? sessionId;
  final bool resumed;
}

/// The agent is starting again with none of the project's history. Worth
/// saying: a user who does not know reads the answer as the agent ignoring
/// everything they established in earlier tasks.
class TaskSessionReset extends TaskEvent {
  const TaskSessionReset(super.seq, this.reason);
  final String reason;
}

/// The provider's own Claude subscription, reporting itself.
///
/// It says nothing about this task's result, and it is the only copy of the
/// reason that reaches the person who submitted the work — the provider's
/// warning goes to a log they cannot read. So when their *next* task sits
/// waiting, this is what explains it.
class TaskCapacity extends TaskEvent {
  const TaskCapacity(super.seq, {this.limitType, this.status, this.resetsAt});
  final String? limitType;

  /// The provider's verdict, kept **verbatim**. What a status means is decided
  /// on the provider; a second reading here is a second thing to disagree.
  final String? status;
  final DateTime? resetsAt;
}

/// A machine picked the task up.
class TaskAttemptStarted extends TaskEvent {
  const TaskAttemptStarted(super.seq, {this.attempt, this.providerId});
  final int? attempt;
  final String? providerId;
}

/// An attempt was lost and the task is starting over from its input.
///
/// The asymmetry matters: the relay resets the **task's** branch, and nothing
/// else. Work an interrupted settle already merged into the member's own branch
/// stays there, which is where their next task is cut from.
class TaskRetry extends TaskEvent {
  const TaskRetry(super.seq, {this.attempt, this.maxAttempts, this.reason});
  final int? attempt;
  final int? maxAttempts;
  final String? reason;
}

/// Somebody stopped this run. On a shared project the person reading it is
/// often not the person who did it, so [by] — a member key — is kept.
class TaskCancelled extends TaskEvent {
  const TaskCancelled(super.seq, {this.by});
  final String? by;
}

/// The agent's own account of the run. [isError] here is the *agent's* claim
/// about itself; the task's real outcome is [TaskTerminal]'s.
class TaskAgentResult extends TaskEvent {
  const TaskAgentResult(
    super.seq, {
    this.subtype,
    this.turns,
    this.durationMs,
    this.isError = false,
  });
  final String? subtype;
  final int? turns;
  final int? durationMs;
  final bool isError;
}

/// The task stopped. The last event of the stream.
class TaskTerminal extends TaskEvent {
  const TaskTerminal(super.seq, {required this.state, this.error});
  final TaskState state;
  final String? error;

  /// Nobody ever claimed it — the grid is short of capacity, not the task at
  /// fault. One word from `deadline_exceeded` and the opposite action.
  bool get queueExpired => error == kQueueExpired;
}

/// A type this build has never seen. Kept rather than dropped: event types
/// grow, and a viewer that rendered only what it knew would show a user
/// nothing while the relay faithfully streamed them what they asked for.
class TaskUnknownEvent extends TaskEvent {
  const TaskUnknownEvent(super.seq, this.type);
  final String type;
}

/// Parse one line of `grid task follow --json`, or null when it isn't one.
///
/// The CLI prints its own diagnostics on stderr and only events on stdout, but
/// a blank line or a stray notice must never take the stream down — a viewer
/// may not die on a diagnostic.
TaskEvent? parseTaskEvent(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final envelope = Map<String, dynamic>.from(decoded);
  final seq = wireInt(envelope, 'seq');
  final body = envelope['event'];
  if (seq == null || body is! Map) return null;
  return _event(seq, Map<String, dynamic>.from(body));
}

TaskEvent _event(int seq, Map<String, dynamic> json) {
  final type = wireString(json, 'type') ?? 'event';
  return switch (type) {
    'task.output' => TaskOutput(seq, json['text'] as String? ?? ''),
    'task.tool_use' => TaskToolUse(
      seq,
      tool: wireString(json, 'tool') ?? 'tool',
      path: wireString(json, 'path'),
    ),
    'task.tool_result' => TaskToolResult(
      seq,
      isError: wireBool(json, 'is_error') ?? false,
      callId: wireString(json, 'id'),
    ),
    'task.stderr' => TaskDiagnostic(seq, json['text'] as String? ?? ''),
    'task.tree' => _tree(seq, json),
    'task.session' => TaskSession(
      seq,
      sessionId: wireString(json, 'session_id'),
    ),
    'task.session_resumed' => TaskSession(
      seq,
      sessionId: wireString(json, 'session_id'),
      resumed: true,
    ),
    'task.session_reset' => TaskSessionReset(
      seq,
      wireString(json, 'reason') ?? 'the transcript could not be used',
    ),
    'task.rate_limit' => TaskCapacity(
      seq,
      limitType: wireString(json, 'limit_type'),
      status: wireString(json, 'status'),
      resetsAt: _epoch(json['resets_at']),
    ),
    'task.attempt_started' => TaskAttemptStarted(
      seq,
      attempt: wireInt(json, 'attempt'),
      providerId: wireString(json, 'provider_id'),
    ),
    'task.retry' => TaskRetry(
      seq,
      attempt: wireInt(json, 'attempt'),
      maxAttempts: wireInt(json, 'max_attempts'),
      reason: wireString(json, 'reason'),
    ),
    'task.cancelled' => TaskCancelled(seq, by: wireString(json, 'by')),
    'task.result' => TaskAgentResult(
      seq,
      subtype: wireString(json, 'subtype'),
      turns: wireInt(json, 'num_turns'),
      durationMs: wireInt(json, 'duration_ms'),
      isError: wireBool(json, 'is_error') ?? false,
    ),
    'task.terminal' => TaskTerminal(
      seq,
      state: TaskState.fromWire(wireString(json, 'state')),
      error: wireString(json, 'error'),
    ),
    _ => TaskUnknownEvent(seq, type),
  };
}

TaskTree _tree(int seq, Map<String, dynamic> json) {
  final raw = json['paths'];
  final list = raw is List ? raw : const [];
  final paths = [
    for (final entry in list)
      if (entry is String) entry,
  ];
  final total = wireInt(json, 'total');
  final truncated = wireBool(json, 'truncated') ?? false;
  // Every entry arrived as a string, a count came with it, it agrees with what
  // was delivered, and nothing was cut. Anything less is a prefix.
  final complete =
      paths.length == list.length && !truncated && total == paths.length;
  return TaskTree(
    seq,
    paths: paths,
    total: total,
    truncated: truncated,
    complete: complete,
  );
}

/// A rate-limit reset stamp, which arrives as seconds since the epoch rather
/// than as ISO-8601 like every other time on this wire. Unusable values are
/// dropped: this is a diagnostic, and a diagnostic may never raise.
DateTime? _epoch(Object? value) {
  if (value is! num || value is bool) return null;
  try {
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
    ).toLocal();
  } on Object {
    return null;
  }
}
