import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_projects_controller.dart';
import 'task_event.dart';
import 'task_event_lines.dart';
import 'task_steps_store.dart';

/// How many events one task's live view keeps.
///
/// A real task makes hundreds of tool calls, and every one of them is a line.
/// The cap is memory, not layout: the view has always tailed to
/// [kLiveTaskLines] on its own, so the old 400 never made the screen shorter —
/// it made a long run *forget its own beginning*, and the record written when
/// it ends could then only hold what was left (issue #30).
const _maxEvents = TaskStepsStore.maxLines;

/// How many times a stream that ended with no verdict is remade.
///
/// The CLI already reattaches at the cursor five times before it gives up, so
/// this is the outer bound on *that*: a relay genuinely gone must end up on
/// screen as "lost", not as a process the app respawns forever.
const _maxReattaches = 3;

/// Where a task's live view stands.
sealed class FollowStatus {
  const FollowStatus();
}

/// Opening the stream. Nothing has arrived yet, which for a queued task is
/// where it stays until a provider claims it.
class FollowConnecting extends FollowStatus {
  const FollowConnecting();
}

/// Events are arriving.
class FollowLive extends FollowStatus {
  const FollowLive();
}

/// The task reached a terminal state, and this is the grid's verdict on it.
class FollowFinished extends FollowStatus {
  const FollowFinished(this.terminal);
  final TaskTerminal terminal;
}

/// The stream ended without a verdict and could not be remade. The task itself
/// may well still be running — this says the *view* is gone, never that the
/// work is.
class FollowLost extends FollowStatus {
  const FollowLost(this.message);
  final String message;
}

/// A task's live view: what has arrived, and where the stream stands.
class TaskFeed {
  const TaskFeed({
    this.events = const [],
    this.status = const FollowConnecting(),
  });

  final List<TaskEvent> events;
  final FollowStatus status;

  /// The tree snapshot the task last sent, or null before one arrives. The only
  /// live view of the working directory there is: the provider commits at
  /// terminal boundaries only, so between claim and finish the repository holds
  /// nothing new.
  TaskTree? get workspace {
    for (final event in events.reversed) {
      if (event is TaskTree) return event;
    }
    return null;
  }

  TaskFeed copyWith({List<TaskEvent>? events, FollowStatus? status}) =>
      TaskFeed(events: events ?? this.events, status: status ?? this.status);
}

/// Watch one task while it runs.
///
/// Auto-disposes, and that is what stops a `grid task follow` outliving the
/// screen that opened it: closing the task cancels the subscription, which
/// kills the process.
final taskFollowProvider = NotifierProvider.autoDispose
    .family<TaskFollowController, TaskFeed, String>(TaskFollowController.new);

class TaskFollowController extends Notifier<TaskFeed> {
  TaskFollowController(this.taskId);

  /// The task being watched — the family argument.
  final String taskId;

  StreamSubscription<TaskEvent>? _subscription;

  /// The last event seen. Resuming at this is the whole point of the cursor:
  /// the relay replays exactly what follows, so a remade stream has no gap and
  /// no repeat.
  int _cursor = -1;

  int _reattaches = 0;

  /// The seam and the grid, resolved once. Held rather than re-read on each
  /// reattach so a grid switch cannot move a stream that is already open.
  CodeCli? _cli;
  String? _grid;

  @override
  TaskFeed build() {
    ref.onDispose(() => unawaited(_subscription?.cancel()));
    _cli = ref.read(codeCliProvider);
    _grid = ref.read(codeGridIdProvider);
    if (_cli == null || _grid == null) {
      // Returned rather than written: `build` may not touch `state`, which does
      // not exist yet while it runs.
      return const TaskFeed(
        status: FollowLost('There is no grid to watch this on.'),
      );
    }
    _listen();
    return const TaskFeed();
  }

  /// Open the stream. Never writes state itself — the process starts
  /// asynchronously, so every event arrives after `build` has returned.
  void _listen() {
    final cli = _cli;
    final grid = _grid;
    if (cli == null || grid == null) return;
    _subscription = cli
        .follow(taskFollowArgs(taskId: taskId, grid: grid, afterSeq: _cursor))
        .listen(_onEvent, onError: _onError, onDone: _onDone);
  }

  void _onEvent(TaskEvent event) {
    if (!ref.mounted) return;
    _cursor = event.seq;
    // The run has ended, so this is the moment its record is worth keeping —
    // once, with everything that arrived, rather than on every event.
    if (event is TaskTerminal) _keep([...state.events, event]);
    // Progress refills the budget: a proxy that severs a busy stream every few
    // minutes is followed indefinitely, while a task that is genuinely over
    // costs a few empty reattaches and then stops.
    _reattaches = 0;
    final events = [...state.events, event];
    state = TaskFeed(
      events: events.length <= _maxEvents
          ? events
          : events.sublist(events.length - _maxEvents),
      status: event is TaskTerminal
          ? FollowFinished(event)
          : const FollowLive(),
    );
  }

  void _onError(Object error) {
    if (!ref.mounted) return;
    state = state.copyWith(status: FollowLost('$error'));
  }

  void _onDone() {
    if (!ref.mounted) return;
    // A terminal event already ended this properly — the process exiting after
    // it is the normal case, and `grid task follow` exits non-zero for a task
    // that *failed*, which is a well-delivered answer rather than a fault.
    if (state.status is FollowFinished) return;
    if (_reattaches >= _maxReattaches) {
      state = state.copyWith(
        status: const FollowLost(
          'Lost the live view of this task. It may still be running — reopen '
          'it to watch again.',
        ),
      );
      return;
    }
    _reattaches++;
    unawaited(_subscription?.cancel());
    _listen();
  }

  /// Write down what the run did, so closing the task doesn't throw it away.
  ///
  /// Fired rather than awaited: the screen has an answer to show and must not
  /// wait on a disk write, and a record that failed to save is not a reason to
  /// hold up the verdict.
  void _keep(List<TaskEvent> events) {
    final lines = taskFeedLines(events);
    if (lines.isEmpty) return;
    unawaited(ref.read(taskStepsStoreProvider).save(taskId, lines));
  }

  /// Start over from where the view left off — the action behind a "watch
  /// again" button on a lost stream.
  void reattach() {
    _reattaches = 0;
    unawaited(_subscription?.cancel());
    state = state.copyWith(status: const FollowConnecting());
    _listen();
  }
}
