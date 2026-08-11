import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/section_scaffold.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_task.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/project_actions.dart';
import '../../logic/task_follow_controller.dart';
import 'code_notice.dart';
import 'task_feed_view.dart';

/// One task: what was asked, what the agent is doing about it, and what to do
/// with the answer.
class TaskDetail extends ConsumerWidget {
  const TaskDetail({super.key, required this.projectId, required this.taskId});

  final String projectId;
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(codeTaskProvider(taskId));
    return switch (task) {
      AsyncData(:final value) => _Detail(projectId: projectId, task: value),
      AsyncError(:final error) => SectionScaffold(
        title: 'Task',
        child: ErrorBox(message: '$error'),
      ),
      _ => const LoadingView(),
    };
  }
}

class _Detail extends ConsumerWidget {
  const _Detail({required this.projectId, required this.task});

  final String projectId;
  final CodeTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final feed = ref.watch(taskFollowProvider(task.id));

    return SectionScaffold(
      title: task.summary,
      subtitle: task.state.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Actions(projectId: projectId, task: task),
          if (task.queueExpired) ...[
            const SizedBox(height: 14),
            const CodeNotice(
              message:
                  'No computer picked this up in time. The grid is short of '
                  'machines to run tasks — the task itself was fine, so it is '
                  'worth sending again once somebody is serving.',
            ),
          ],
          if (task.branchPruned) ...[
            const SizedBox(height: 14),
            const CodeNotice(
              message:
                  'The grid no longer keeps this task’s files — they were '
                  'cleared after the project’s retention window. What it did '
                  'is still recorded here.',
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Expanded(child: TaskFeedView(feed: feed)),
          if (task.resultText case final result?) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _Result(text: result),
          ],
        ],
      ),
    );
  }
}

/// What can be done with this task right now.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.projectId, required this.task});

  final String projectId;
  final CodeTask task;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  CodeTask get _task => widget.task;

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(codeTasksProvider(widget.projectId).notifier)
          .cancel(_task.id);
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message:
              'Stopped — it is now ${result.state.label.toLowerCase()}. '
              'Whatever the agent had done is still there to fetch.',
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

  Future<void> _getResult() async {
    final folder = await getDirectoryPath(confirmButtonText: 'Put it here');
    if (folder == null || !mounted) return;
    setState(() => _busy = true);
    try {
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: () =>
              ref.read(selectedCodeTaskProvider.notifier).select(null),
          child: const Text('Back to the project'),
        ),
        if (_task.state.isActive)
          OutlinedButton(
            onPressed: _busy ? null : _stop,
            child: const Text('Stop it'),
          ),
        if (_task.hasFetchableBranch)
          FilledButton(
            onPressed: _busy ? null : _getResult,
            child: const Text('Get the result'),
          ),
      ],
    );
  }
}

/// The agent's closing words. Kept at the foot, under everything it did.
class _Result extends StatelessWidget {
  const _Result({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: SelectableText(
          text.trimRight(),
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: AppPalette.textPrimary,
          ),
        ),
      ),
    );
  }
}
