import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../logic/code_tasks_controller.dart';
import 'code_failure.dart';
import 'task_turn.dart';

/// How wide the conversation gets on a big window.
///
/// The same measure as the chat's transcript, so the two halves of the app read
/// at the same line length. Prose inside a turn is held narrower still by
/// `MessageContent`, which leaves this width to the things that need it — a
/// command, a path, a table.
const double kTaskColumnWidth = 1000;

/// Everything the team has run in this project, oldest at the top.
///
/// Reversed rather than scroll-managed: the list is newest-first as the grid
/// sends it, so drawing it in reverse puts the newest turn at the bottom and
/// pins the view there. A task that starts talking grows the bottom turn
/// upwards, with no scroll arithmetic to get wrong.
class TaskTranscript extends ConsumerWidget {
  const TaskTranscript({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(codeTasksProvider(projectId));
    return switch (tasks) {
      AsyncData(:final value) when value.isEmpty => const _NothingYet(),
      AsyncData(:final value) => ListView.builder(
        reverse: true,
        itemCount: value.length,
        itemBuilder: (context, index) {
          final task = value[index];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kTaskColumnWidth),
              // Keyed by the task, not by its place in the list: a new task is
              // prepended on every poll, so an index-keyed turn would hand the
              // "showing what it did" of one task to whichever task slid into
              // its position.
              child: TaskTurn(
                key: ValueKey(task.id),
                projectId: projectId,
                task: task,
              ),
            ),
          );
        },
      ),
      AsyncError(:final error) => CodeFailure(
        message: '$error',
        onRetry: () => ref.invalidate(codeTasksProvider(projectId)),
      ),
      _ => const LoadingView(),
    };
  }
}

/// Nothing has been run here yet. No button: the box at the foot of the page is
/// the action, and it is already on screen a few inches below.
class _NothingYet extends StatelessWidget {
  const _NothingYet();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: LucideIcons.messageSquareCode300,
    title: 'Nothing has been run here yet',
    message:
        'Say what you want done. A computer on the grid runs it against this '
        'project and pushes the result to your own branch.',
  );
}
