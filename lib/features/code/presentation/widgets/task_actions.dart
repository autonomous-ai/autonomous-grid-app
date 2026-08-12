import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/toast.dart';
import '../../logic/code_task.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/project_status_controller.dart';

/// Stop a task that is still going, from the turn it belongs to.
///
/// The only thing there is to do to a task in the conversation. A finished one
/// is read, not managed: its answer is the reply above it, and its files reach
/// this member through the project's own "Catch up" and "Get a copy" — the same
/// two verbs that move every other change, so a task result is not a fourth kind
/// of thing to learn.
class TaskActions extends ConsumerStatefulWidget {
  const TaskActions({super.key, required this.projectId, required this.task});

  final String projectId;
  final CodeTask task;

  @override
  ConsumerState<TaskActions> createState() => _TaskActionsState();
}

class _TaskActionsState extends ConsumerState<TaskActions> {
  /// Held while the cancel is out, so a second press can't send a second one.
  bool _busy = false;

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(codeTasksProvider(widget.projectId).notifier)
          .cancel(widget.task.id);
      // The slot this held is free now; the box at the foot of the page is
      // disabled until the status says so, so read it back rather than wait.
      await ref
          .read(projectStatusProvider(widget.projectId).notifier)
          .refresh();
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message:
              'Stopped — it is now ${result.state.label.toLowerCase()}. '
              'Whatever the agent had done is kept on your branch.',
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: '$error', severity: ToastSeverity.error),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.task.state.isActive) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: _busy ? null : _stop,
        child: const Text('Stop it'),
      ),
    );
  }
}
