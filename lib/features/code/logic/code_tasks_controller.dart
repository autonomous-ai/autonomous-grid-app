import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_projects_controller.dart';
import 'code_task.dart';
import 'code_write_results.dart';
import 'poll_cadence.dart';

/// Every member's tasks in a project, oldest first — the order the grid returns
/// them (`created_at` ascending), which the transcript shows as-is. Refreshed on
/// a timer while the screen is open.
///
/// The whole team's, not only this member's: a project is shared, and "what is
/// the team running right now" is the question this list exists to answer.
final codeTasksProvider = AsyncNotifierProvider.autoDispose
    .family<CodeTasksController, List<CodeTask>, String>(
      CodeTasksController.new,
      retry: neverRetryCodeCommand,
    );

class CodeTasksController extends AsyncNotifier<List<CodeTask>> {
  CodeTasksController(this.projectId);

  /// The project whose tasks these are — the family argument.
  final String projectId;

  Timer? _timer;

  @override
  Future<List<CodeTask>> build() async {
    ref.onDispose(() => _timer?.cancel());
    final tasks = await _read();
    _schedule(tasks);
    return tasks;
  }

  Future<List<CodeTask>> _read() async {
    // No `--limit`: the project reads as one conversation, so the transcript
    // wants the project's whole history, not a first page of it. The relay caps
    // the answer at its own maximum, and there is no "more" to page to here.
    final json = await requireCodeCli(ref).object(
      taskListArgs(projectId: projectId, grid: requireCodeGrid(ref), all: true),
    );
    if (!TaskPage.carriesTasks(json)) {
      // Checked on presence, not truthiness. An empty list is a real answer; a
      // body a proxy had stripped is not, and reporting it as "nobody is
      // working" is what somebody polling a shared project would act on.
      throw const CodeGridException(
        'The grid did not send a list of tasks, so this cannot be shown as '
        'one. Try again in a moment.',
      );
    }
    return TaskPage.fromJson(json).tasks;
  }

  void _schedule(List<CodeTask> tasks) {
    _timer?.cancel();
    final busy = tasks.any((task) => task.state.isActive);
    _timer = Timer(busy ? kBusyPoll : kIdlePoll, _tick);
  }

  Future<void> _tick() async {
    // A failed poll leaves the good list on screen: one blinking request is
    // not a reason to blank a pane somebody is reading.
    try {
      final tasks = await _read();
      if (!ref.mounted) return;
      state = AsyncData(tasks);
      _schedule(tasks);
    } on Object {
      if (!ref.mounted) return;
      _timer?.cancel();
      _timer = Timer(kIdlePoll, _tick);
    }
  }

  /// Hand the grid a task and queue it for a provider.
  ///
  /// [files] are `LOCAL[:DEST]` specs, committed **before** any provider can
  /// claim it — so the agent always finds them.
  ///
  /// One task in flight per member per project: a second one while yours is
  /// running is refused, and the refusal names the task holding the slot. The
  /// screen reads that from `project status` and does not offer the button, so
  /// this failing that way means the status was a few seconds stale.
  Future<CodeTask> create({
    required String prompt,
    List<String> files = const [],
  }) async {
    final json = await requireCodeCli(ref).object(
      taskCreateArgs(
        projectId: projectId,
        prompt: prompt,
        grid: requireCodeGrid(ref),
        files: files,
      ),
    );
    final task = CodeTask.fromJson(json);
    if (task == null) {
      throw const CodeGridException(
        'The grid took the task but did not say what its id is, so there is '
        'nothing to follow. Check the list in a moment before sending it '
        'again — it may well be running.',
      );
    }
    await refresh();
    return task;
  }

  /// Stop a task that has not finished, freeing its member's slot at once.
  ///
  /// The agent stops within about half a minute, on the provider's next lease
  /// renewal. **Nothing is rewound** — the branch is left where the agent got
  /// to, so the result is still fetchable.
  ///
  /// A project is shared, so any member may cancel any task in it: the person
  /// whose merge has been stuck all afternoon is often the one who needs to
  /// stop it. The relay's event log records who did.
  Future<CancelResult> cancel(String taskId) async {
    final json = await requireCodeCli(
      ref,
    ).object(taskCancelArgs(taskId: taskId, grid: requireCodeGrid(ref)));
    final result = CancelResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not say what state the task is in now, so this cannot be '
        'reported as stopped. Check the task before starting another.',
      );
    }
    await refresh();
    return result;
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_read);
    final tasks = state.asData?.value;
    if (tasks != null) _schedule(tasks);
  }
}
