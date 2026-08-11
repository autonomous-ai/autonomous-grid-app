import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/layouts/widgets/rail_section_header.dart';
import '../../../../shared/layouts/widgets/sidebar_item.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/code_task.dart';
import '../../logic/code_tasks_controller.dart';
import 'rail_note.dart';

/// What the team has run in the open project, newest first.
class CodeTaskRows extends ConsumerWidget {
  const CodeTaskRows({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(codeTasksProvider(projectId));
    final openTask = ref.watch(selectedCodeTaskProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RailSectionHeader(label: 'Tasks'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: switch (tasks) {
            AsyncData(:final value) when value.isEmpty => const RailNote(
              'Nothing has been run here yet.',
            ),
            AsyncData(:final value) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final task in value)
                  SidebarItem(
                    label: task.summary,
                    selected: task.id == openTask,
                    revealLabelOnHover: true,
                    badge: _StateBadge(state: task.state),
                    onTap: () => ref
                        .read(selectedCodeTaskProvider.notifier)
                        .select(task.id),
                  ),
              ],
            ),
            AsyncError() => RailNote(
              'Couldn’t read this project’s tasks.',
              onRetry: () => ref.invalidate(codeTasksProvider(projectId)),
            ),
            _ => const RailNote('Loading…'),
          },
        ),
      ],
    );
  }
}

/// A task's state as one dot, so a rail row says how it went without a word.
///
/// The pulse is reserved for work that is genuinely moving — a queued task is
/// waiting on somebody else's machine, and a breathing dot would claim
/// otherwise.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});

  final TaskState state;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final colour = switch (state) {
      TaskState.running || TaskState.completed => AppPalette.online,
      TaskState.queued => AppPalette.warn,
      // A run that failed and a state this build cannot read are not the same
      // news: one is a result, the other is "we don't know". Grey for the
      // second would flatten a failure into a shrug in the one place a person
      // scans for it.
      TaskState.failed ||
      TaskState.timedOut => Theme.of(context).colorScheme.error,
      TaskState.unknown => AppPalette.offline,
    };
    // A dot is colour alone, which says nothing to a screen reader and nothing
    // to somebody who cannot tell these two greens apart.
    return Semantics(
      label: state.label,
      child: StatusDot(color: colour, pulsing: state == TaskState.running),
    );
  }
}
