import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_projects_controller.dart';
import 'code_task.dart';
import 'code_write_results.dart';
import 'poll_cadence.dart';

/// How many tasks one page holds. The relay's own maximum is 200; a screen
/// showing a project's recent work does not need that much history, and the
/// page after this one is a click away.
const _pageSize = 50;

/// Every member's tasks in a project, newest first — refreshed on a timer while
/// the screen is open.
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

  /// The page cursor the last read handed back, or null when this is the whole
  /// list. Said out loud on screen: a page that silently stops at the limit
  /// reads as the project's entire history.
  String? nextAfter;

  @override
  Future<List<CodeTask>> build() async {
    ref.onDispose(() => _timer?.cancel());
    final tasks = await _read();
    _schedule(tasks);
    return tasks;
  }

  Future<List<CodeTask>> _read() async {
    final json = await requireCodeCli(ref).object(
      taskListArgs(
        projectId: projectId,
        grid: requireCodeGrid(ref),
        all: true,
        limit: _pageSize,
      ),
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
    final page = TaskPage.fromJson(json);
    nextAfter = page.nextAfter;
    return page.tasks;
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

/// The task open in the Code pane, or null when the project overview is shown.
/// Cleared when the project changes — a task id belongs to one project.
final selectedCodeTaskProvider = NotifierProvider<SelectedCodeTask, String?>(
  SelectedCodeTask.new,
);

class SelectedCodeTask extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(selectedCodeProjectProvider);
    return null;
  }

  void select(String? taskId) => state = taskId;
}

/// One task, read fresh — the whole row, including the result text a list row
/// does not carry.
final codeTaskProvider = FutureProvider.autoDispose.family<CodeTask, String>((
  ref,
  taskId,
) async {
  final grid = requireCodeGrid(ref);
  final json = await requireCodeCli(
    ref,
  ).object(taskGetArgs(taskId: taskId, grid: grid));
  final task = CodeTask.fromJson(json);
  if (task == null) {
    throw const CodeGridException(
      'The grid did not send this task back. It may have been cleaned up after '
      "the project's retention window.",
    );
  }
  return task;
});
