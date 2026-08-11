import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../logic/code_cli.dart';
import '../logic/code_projects_controller.dart';
import '../logic/code_tasks_controller.dart';
import 'widgets/cli_too_old_view.dart';
import 'widgets/new_project_dialog.dart';
import 'widgets/project_overview.dart';
import 'widgets/task_detail.dart';

/// The right-hand pane in Code mode.
///
/// Four things can be true, in this order: the grid tool on this computer may
/// not know about shared projects at all, there may be no grid selected, there
/// may be no project open, and there may or may not be a task open inside it.
/// Each has its own screen with its own next step — none of them is a blank
/// pane.
class CodePane extends ConsumerWidget {
  const CodePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(codeCliSupportedProvider);
    return switch (supported) {
      AsyncData(value: false) => const CliTooOldView(),
      AsyncError(:final error) => SectionScaffold(
        title: 'Code',
        child: ErrorBox(message: "Couldn't check the grid tool: $error"),
      ),
      AsyncData(value: true) => const _Workspace(),
      _ => const LoadingView(),
    };
  }
}

/// The pane once the tool is known to be able to do this.
class _Workspace extends ConsumerWidget {
  const _Workspace();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(codeGridIdProvider) == null) return const _NoGrid();

    final projectId = ref.watch(selectedCodeProjectProvider);
    if (projectId == null) return const _NoProjectOpen();

    final taskId = ref.watch(selectedCodeTaskProvider);
    if (taskId == null) return ProjectOverview(projectId: projectId);
    return TaskDetail(projectId: projectId, taskId: taskId);
  }
}

/// Nothing to act on: shared projects belong to a grid, and none is selected.
class _NoGrid extends ConsumerWidget {
  const _NoGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionScaffold(
    title: 'Code',
    subtitle: 'Hand coding work to your team’s grid.',
    child: EmptyState(
      icon: LucideIcons.zap300,
      title: 'Pick a grid first',
      message: 'A shared project lives on one grid, and none is chosen yet.',
      // A button rather than the name of a screen: the grid picker has moved
      // between screens before, and copy naming a place is copy that goes
      // stale silently.
      action: FilledButton(
        onPressed: () => ref
            .read(shellSectionProvider.notifier)
            .select(ShellSection.engines),
        child: const Text('Choose a grid'),
      ),
    ),
  );
}

/// A grid is selected but no project is open — either there are none yet, or
/// the user has not chosen one.
class _NoProjectOpen extends ConsumerWidget {
  const _NoProjectOpen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(codeProjectsProvider);
    return SectionScaffold(
      title: 'Code',
      subtitle:
          'Post a task, someone on the grid runs a coding agent on it, and the '
          'result comes back on your own branch.',
      child: switch (projects) {
        AsyncData(:final value) when value.isEmpty => EmptyState(
          icon: LucideIcons.folderGit2300,
          title: 'No shared projects yet',
          message:
              'Start one and bring a repository into it. Everyone you add gets '
              'their own copy of the work, and nobody can push over anybody '
              "else's.",
          action: FilledButton.icon(
            onPressed: () => showNewProjectDialog(context),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('New shared project'),
          ),
        ),
        AsyncData() => const EmptyState(
          icon: LucideIcons.folderGit2300,
          title: 'Open a project',
          message:
              'Pick one from the list on the left to see where it is and '
              'what has been run against it.',
        ),
        AsyncError(:final error) => _Failed(
          message: '$error',
          onRetry: () => ref.invalidate(codeProjectsProvider),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

/// A failure with the one action that can clear it.
///
/// The grid's commands are not retried behind the user's back — a refusal is a
/// verdict, and asking again ten times only spends processes — so the way out
/// has to be a button they can see.
class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ErrorBox(message: message),
      const SizedBox(height: 10),
      OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
    ],
  );
}
