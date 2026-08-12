import 'code_task.dart';
import 'task_event.dart';

/// How a line of a task's live view should read.
enum TaskLineTone {
  /// The agent's own words.
  prose,

  /// Something it did — a tool call. Most of a task is these.
  step,

  /// A disclosure about the run rather than about the work: a retry, the
  /// provider's subscription, a session starting fresh.
  note,

  /// How it ended.
  verdict,
}

/// One line of a task's live view, or null for an event with nothing to show.
///
/// Pure, and tested, because this is where the run is translated into what a
/// person reads — and two of these lines are the *only* copy of facts nobody
/// else will ever tell them: that an attempt was thrown away and started over,
/// and that the machine running it is out of subscription headroom.
///
/// A successful tool result returns null on purpose. One arrives for every
/// call and a real task makes hundreds; the call was already announced by its
/// own line, so narrating the successes would double the length of the view
/// with rows whose only content is an id nobody can act on.
({String text, TaskLineTone tone})? taskEventLine(TaskEvent event) {
  return switch (event) {
    TaskOutput(:final text) when text.trim().isEmpty => null,
    TaskOutput(:final text) => (
      text: text.trimRight(),
      tone: TaskLineTone.prose,
    ),
    TaskToolUse(:final tool, :final path) => (
      text: path == null ? tool : '$tool  $path',
      tone: TaskLineTone.step,
    ),
    TaskToolResult(isError: false) => null,
    TaskToolResult() => (text: 'A tool call failed.', tone: TaskLineTone.note),
    TaskDiagnostic(:final text) when text.trim().isEmpty => null,
    TaskDiagnostic(:final text) => (
      text: text.trimRight(),
      tone: TaskLineTone.note,
    ),
    // The tree is shown as a workspace panel of its own, not as a line in the
    // feed: it is a snapshot re-sent in full every time, and printing it again
    // every thirty seconds buries everything else.
    TaskTree() => null,
    TaskSession(resumed: true) => (
      text: 'Picking up where it left off.',
      tone: TaskLineTone.note,
    ),
    TaskSession() => null,
    TaskSessionReset(:final reason) => (
      text:
          'Starting fresh, with none of the earlier conversation ($reason). '
          'It will not remember what you asked in previous tasks.',
      tone: TaskLineTone.note,
    ),
    TaskCapacity(:final status, :final resetsAt) => (
      text:
          'The computer running this reports its Claude subscription as '
          '${status ?? 'unknown'}'
          '${resetsAt == null ? '' : ', resetting ${_clock(resetsAt)}'}.',
      tone: TaskLineTone.note,
    ),
    TaskAttemptStarted(:final providerId) => (
      text: providerId == null
          ? 'A computer picked this up.'
          : 'Running on $providerId.',
      tone: TaskLineTone.note,
    ),
    TaskRetry(:final reason) => (
      text:
          'That attempt was lost (${reason ?? 'its lease lapsed'}), so it is '
          'starting again from the beginning. Anything it did outside the '
          'repository is not undone.',
      tone: TaskLineTone.note,
    ),
    TaskCancelled(:final by) => (
      text:
          '${by == null ? 'Someone on the project' : 'Project member $by'} '
          'stopped this. Whatever the agent had done is still there.',
      tone: TaskLineTone.note,
    ),
    TaskAgentResult(:final turns, :final durationMs) => (
      text: 'The agent finished${_effort(turns, durationMs)}.',
      tone: TaskLineTone.note,
    ),
    TaskTerminal() => (text: terminalLine(event), tone: TaskLineTone.verdict),
    TaskUnknownEvent(:final type) => (text: type, tone: TaskLineTone.note),
  };
}

/// How a task ended, in a sentence.
///
/// `queue_expired` gets its own, because "ran out of time" reads as "the task
/// hung" and this one never started: the grid was short of computers, and the
/// action is to add one rather than to fix the prompt.
///
/// Taken apart from both shapes that carry the same three facts — the live
/// stream's last event and the listed task — so a run cannot be described one
/// way while it is watched and another way afterwards.
String taskEndedLine({
  required TaskState state,
  required bool queueExpired,
  String? error,
}) {
  if (queueExpired) {
    return 'No computer picked this up in time. The grid is short of machines '
        'to run tasks — nothing was wrong with the task itself.';
  }
  return switch (state) {
    TaskState.completed => 'Done.',
    TaskState.failed => 'It failed${error == null ? '' : ': $error'}.',
    TaskState.timedOut => 'It ran out of time while working.',
    TaskState.queued ||
    TaskState.running ||
    TaskState.unknown => 'It stopped${error == null ? '' : ': $error'}.',
  };
}

/// How the stream said it ended.
String terminalLine(TaskTerminal event) => taskEndedLine(
  state: event.state,
  queueExpired: event.queueExpired,
  error: event.error,
);

/// How a finished task ended, for a turn whose agent left no closing words —
/// the transcript would otherwise show the question and nothing under it.
String taskVerdict(CodeTask task) => taskEndedLine(
  state: task.state,
  queueExpired: task.queueExpired,
  error: task.error,
);

/// " (12 turns, 34.5s)" — each part dropped unless it is usable.
String _effort(int? turns, int? durationMs) {
  final parts = [
    if (turns != null) '$turns turns',
    if (durationMs != null) '${(durationMs / 1000).toStringAsFixed(1)}s',
  ];
  return parts.isEmpty ? '' : ' (${parts.join(', ')})';
}

String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
