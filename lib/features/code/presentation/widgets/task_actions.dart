import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_task.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/project_actions.dart';
import '../../logic/project_status_controller.dart';

/// What can be done with one task, under the turn it belongs to: stop it while
/// it is going, take its files once it has stopped, and read what it did.
///
/// Quiet text buttons rather than a toolbar: the transcript is a conversation,
/// and every turn in it carries this row.
class TaskActions extends ConsumerStatefulWidget {
  const TaskActions({
    super.key,
    required this.projectId,
    required this.task,
    required this.showSteps,
    required this.onToggleSteps,
  });

  final String projectId;
  final CodeTask task;

  /// Whether this turn is currently showing everything the agent did.
  final bool showSteps;

  /// Shows or hides that. Null while the task is still going — its steps are
  /// already on screen and there is nothing to unfold.
  final VoidCallback? onToggleSteps;

  @override
  ConsumerState<TaskActions> createState() => _TaskActionsState();
}

class _TaskActionsState extends ConsumerState<TaskActions> {
  /// Held while a command is out, so a second press cannot start a second one.
  bool _busy = false;

  CodeTask get _task => widget.task;

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        ToastScope.show(
          context,
          ToastSpec(message: '$error', severity: ToastSeverity.error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() => _guard(() async {
    final result = await ref
        .read(codeTasksProvider(widget.projectId).notifier)
        .cancel(_task.id);
    // The slot this was holding is free now, and the box at the foot of the
    // page is disabled until the status says so.
    await ref.read(projectStatusProvider(widget.projectId).notifier).refresh();
    if (!mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message:
            'Stopped — it is now ${result.state.label.toLowerCase()}. '
            'Whatever the agent had done is still there to fetch.',
      ),
    );
  });

  Future<void> _getResult() async {
    final folder = await getDirectoryPath(confirmButtonText: 'Put it here');
    if (folder == null || !mounted) return;
    await _guard(() async {
      final result = await ref
          .read(projectActionsProvider)
          .fetch(taskId: _task.id, into: folder);
      await ref.read(hostShellServiceProvider).openFolder(result.path);
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message: result.isInputOnly
              // Said out loud: a folder of the task's own input files reads as
              // a result until somebody notices nothing changed.
              ? 'Fetched, but this task never wrote anything — the folder '
                    'holds what it started from.'
              : 'Fetched into ${result.path}.',
          severity: result.isInputOnly
              ? ToastSeverity.warning
              : ToastSeverity.success,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final toggle = widget.onToggleSteps;
    return Wrap(
      spacing: 4,
      children: [
        if (_task.state.isActive)
          TextButton(
            onPressed: _busy ? null : _stop,
            child: const Text('Stop it'),
          ),
        if (_task.hasFetchableBranch)
          TextButton(
            onPressed: _busy ? null : _getResult,
            child: const Text('Get the result'),
          ),
        if (toggle != null)
          TextButton(
            onPressed: toggle,
            child: Text(
              widget.showSteps ? 'Hide what it did' : 'Show what it did',
            ),
          ),
      ],
    );
  }
}
