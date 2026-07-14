import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/hermes_tool.dart';
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
              _ => const Center(child: CircularProgressIndicator()),
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
          child: open == null
              ? const _PickOne()
              : JobDetail(key: ValueKey(open.id), job: open),
        ),
      ],
    );
  }
}

/// The list column's main action. Sized to the pills and the search box under it
/// — one toolbar, one height.
class _NewTaskButton extends StatelessWidget {
  const _NewTaskButton();

  /// What the filter pills use (`PillChoice.height`), so the toolbar lines up.
  static const double _height = 34;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => showNewJobDialog(context),
      icon: const Icon(Icons.add_rounded, size: 18),
      style: FilledButton.styleFrom(
        // Without this, Material pads the button out to a 48px tap target and
        // the capsule floats in a box half again its own height.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size.fromHeight(_height),
        maximumSize: const Size.fromHeight(_height),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
      label: const Text('New task'),
    );
  }
}

/// Nothing open in the right pane yet.
class _PickOne extends StatelessWidget {
  const _PickOne();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Pick a task to see what it does.',
        style: TextStyle(color: AppPalette.textFaint),
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
              const Text(
                'No scheduled tasks yet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
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
            const Text(
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
