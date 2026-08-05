import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/layouts/shell_state.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../../agents/logic/adapters/hermes_tool.dart';
import '../../../scheduled/logic/scheduled_job.dart';
import '../../../scheduled/logic/scheduled_jobs_controller.dart';
import '../../../scheduled/presentation/widgets/new_job_dialog.dart';
import '../../logic/project.dart';
import '../../logic/project_tasks_store.dart';
import 'rail_card.dart';

/// The rail's Scheduled card: the tasks the assistant runs on its own for this
/// project, on a timer.
///
/// Hermes's scheduler doesn't know about projects, so the app keeps the link
/// ([projectJobIdsProvider]); a task created here runs in the project's folder
/// and shows only under it. Tapping a task opens it in the Scheduled screen.
class ProjectScheduledCard extends ConsumerWidget {
  const ProjectScheduledCard({required this.project, super.key});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(hermesInstalledProvider);
    return RailCard(
      icon: Icons.schedule_rounded,
      title: 'Scheduled',
      trailing: installed
          ? IconButton(
              tooltip: 'New scheduled task for this project',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: AppPalette.textSecondary,
              icon: const Icon(Icons.add_rounded),
              onPressed: () => showNewJobDialog(context, project: project),
            )
          : null,
      child: installed
          ? _body(context, ref)
          : const RailHint(
              'Scheduling needs this computer set up to run tasks. Open the '
              'account menu ▸ This computer to finish setting it up.',
            ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(projectJobIdsProvider(project.id));
    return switch (ref.watch(scheduledJobsProvider)) {
      AsyncData(:final value) => _list(context, ref, [
        for (final job in value)
          if (ids.contains(job.id)) job,
      ]),
      AsyncError() => const RailHint(
        "Couldn't read this project's scheduled tasks.",
      ),
      _ => const RailHint('Loading…'),
    };
  }

  Widget _list(BuildContext context, WidgetRef ref, List<ScheduledJob> mine) {
    if (mine.isEmpty) {
      return const RailHint(
        'No scheduled tasks for this project yet. Add one with + to have the '
        'assistant work on it on a timer.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final job in mine)
          _JobRow(
            job: job,
            onTap: () {
              ref.read(selectedJobIdProvider.notifier).select(job.id);
              ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.scheduled);
            },
          ),
      ],
    );
  }
}

/// One task in the card: a status dot, its name, and a plain-word state. The
/// detail (schedule, last runs) lives one tap away in the Scheduled screen.
class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.onTap});

  final ScheduledJob job;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final (color, state) = _status;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          child: Row(
            children: [
              StatusDot(color: color, size: 8),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      state,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppPalette.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppPalette.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }

  (Color, String) get _status {
    if (!job.enabled) return (AppPalette.offline, 'Paused');
    if (job.failed) return (AppPalette.warn, 'Last run failed');
    return (AppPalette.online, 'Scheduled');
  }
}
