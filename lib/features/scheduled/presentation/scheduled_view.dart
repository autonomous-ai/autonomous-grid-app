import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/job_schedule.dart';
import '../logic/scheduled_job.dart';
import '../logic/scheduled_jobs_controller.dart';
import 'widgets/job_detail.dart';
import 'widgets/job_list.dart';
import 'widgets/job_suggestion_list.dart';
import 'widgets/new_job_dialog.dart';
import 'widgets/scheduler_banner.dart';
import 'widgets/task_power_bar.dart';

/// The Scheduled screen: work the assistant does on its own, on a timer.
///
/// The tasks are Hermes's own scheduled jobs — the app writes them through
/// `hermes cron` and reads them back from its store, so it never keeps a second
/// list that could drift from what actually runs.
class ScheduledView extends ConsumerWidget {
  const ScheduledView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hermesInstalledProvider)) return const _NoAgent();

    final jobs = ref.watch(scheduledJobsProvider);
    return SectionScaffold(
      title: 'Scheduled',
      subtitle:
          'Tasks the assistant runs on its own — every morning, every Friday, '
          'whenever you say. The answer is waiting when you come back.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SchedulerBanner(),
          const TaskPowerBar(),
          Expanded(
            child: switch (jobs) {
              AsyncData(:final value) when value.isEmpty => const _NoJobs(),
              AsyncData(:final value) => _Workspace(jobs: value),
              AsyncError(:final error) => ErrorBox(
                message: "Couldn't read your scheduled tasks: $error",
              ),
              _ => const LoadingView(),
            },
          ),
        ],
      ),
    );
  }
}

/// The two-pane working view: the tasks on the left, the open one on the right.
class _Workspace extends ConsumerWidget {
  const _Workspace({required this.jobs});

  final List<ScheduledJob> jobs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedJobIdProvider);
    final open = jobs.where((job) => job.id == selectedId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 330,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _NewTaskButton(),
              const SizedBox(height: 14),
              Expanded(child: JobList(jobs: jobs)),
            ],
          ),
        ),
        const SizedBox(width: 14),
        const VerticalDivider(width: 1),
        const SizedBox(width: 30),
        Expanded(
          // A short cross-fade when the open task changes, so switching rows
          // reads as a transition rather than a hard cut. Keyed by task id (and
          // a sentinel for the empty state) so the switcher knows when to run.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            // Fade only — no slide. The panes are full-height; sliding them would
            // fight the list's own layout and feel busier, not smoother.
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: open == null
                ? const _PickOne(key: ValueKey('pick-one'))
                : JobDetail(key: ValueKey(open.id), job: open),
          ),
        ),
      ],
    );
  }
}

/// The list column's main action, sized to the search box under it.
class _NewTaskButton extends StatelessWidget {
  const _NewTaskButton();

  /// Taller than a standard control on purpose — it's the column's one real
  /// action, and it lines up with the search field below it. The only thing this
  /// button overrides; shape, label and padding come from the app's button theme.
  static const double _height = 40;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => showNewJobDialog(context),
      icon: const Icon(Icons.add_rounded, size: AppControl.iconSize),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(_height),
        maximumSize: const Size.fromHeight(_height),
      ),
      label: const Text('New task'),
    );
  }
}

/// Nothing open in the right pane yet — so instead of an empty prompt, show what
/// the tasks have been doing. Recent runs across every task, newest first, each
/// a shortcut into that task. An idle selection still proves the work is happening.
class _PickOne extends ConsumerWidget {
  const _PickOne({super.key});

  /// A peek per run — enough to recognise it, not enough to read it here.
  static const int _previewLines = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final activity = ref.watch(recentActivityProvider);

    return switch (activity) {
      AsyncData(:final value) when value.isEmpty => Center(
        child: Text(
          'Pick a task to see what it does.\n'
          'When one runs, its answer shows up here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.textFaint, height: 1.4),
        ),
      ),
      AsyncData(:final value) => ListView(
        padding: const EdgeInsets.only(right: 4),
        children: [
          Text(
            'Recent activity',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The latest from your tasks. Pick one to open it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          for (final run in value.take(8))
            _ActivityCard(run: run, previewLines: _previewLines),
        ],
      ),
      _ => const LoadingView(),
    };
  }
}

/// One recent run in the activity feed: which task, when, and the top of what it
/// said. Tapping it opens that task in the pane.
class _ActivityCard extends ConsumerWidget {
  const _ActivityCard({required this.run, required this.previewLines});

  final JobRun run;
  final int previewLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final lines = run.text.split('\n');
    final preview = lines.take(previewLines).join('\n').trim();
    final radius = BorderRadius.circular(14);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppCard.base,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () =>
              ref.read(selectedJobIdProvider.notifier).select(run.jobId),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        run.jobName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      jobTimeLabel(run.at),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textFaint,
                      ),
                    ),
                  ],
                ),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    preview,
                    maxLines: previewLines,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// No tasks yet — offer three to start from, plus the blank form.
class _NoJobs extends StatelessWidget {
  const _NoJobs();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'No scheduled tasks yet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'A task runs on this computer, reads your Projects folder, and '
                'leaves you the answer.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 22),
              const JobSuggestionList(),
              const SizedBox(height: 18),
              Center(
                child: OutlinedButton.icon(
                  onPressed: () => showNewJobDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Write my own'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Nothing on this computer can run a task yet.
class _NoAgent extends ConsumerWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Scheduled',
      subtitle: 'Tasks the assistant runs on its own, on a timer.',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "This computer isn't set up to answer chats yet, so it has "
              'nothing to run a task with.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.engines),
              child: const Text('Set up this computer'),
            ),
          ],
        ),
      ),
    );
  }
}
