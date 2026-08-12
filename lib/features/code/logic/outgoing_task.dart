import 'package:flutter/foundation.dart';

/// A task the user has already sent that the grid has not taken yet.
///
/// It exists so the question can be on screen before the round trips that
/// register it. Sending is three `grid` calls deep — catch up, create, re-read
/// the status — and a paragraph left sitting in the box for those seconds reads
/// as an app that ate the Enter key. So the turn goes up at once and this
/// carries it until the real task takes its place in the transcript.
///
/// It is also where the text lives from the moment the box is cleared: nothing
/// else holds it, so a send the grid refuses hands it back here rather than
/// losing it.
@immutable
class OutgoingTask {
  OutgoingTask({
    required this.prompt,
    required List<String> files,
    required this.phase,
  }) : files = List.unmodifiable(files);

  /// What was typed, exactly as it will be asked.
  final String prompt;

  /// The `LOCAL[:DEST]` specs attached to it, kept for the same reason as
  /// [prompt]: sending again has to send the same task, files and all.
  final List<String> files;

  final OutgoingPhase phase;

  /// The same turn, refused — the question stays, and [message] says why.
  OutgoingTask refused(String message) => OutgoingTask(
    prompt: prompt,
    files: files,
    phase: TaskSendFailed(message),
  );
}

/// Where an [OutgoingTask] has got to.
sealed class OutgoingPhase {
  const OutgoingPhase();
}

/// On its way: catching up, or waiting on the grid to take it.
final class TaskSending extends OutgoingPhase {
  const TaskSending();
}

/// It never got there. [message] is the reason, already in words a person can
/// read — a merge holding this member's one slot, or a grid that didn't answer.
final class TaskSendFailed extends OutgoingPhase {
  const TaskSendFailed(this.message);

  final String message;
}
