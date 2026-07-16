import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../../shared/layouts/shell_state.dart';
import '../../../../shared/theme/app_theme.dart';
// Imported here for the part files below (job_detail_actions/_results), which
// share this library's imports.
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../logic/cron_error.dart';
import '../../logic/job_schedule.dart';
import '../../logic/job_status.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';
import '../../logic/task_delivery.dart';
import 'status_pill.dart';

part 'job_detail_actions.dart';
part 'job_detail_facts.dart';
part 'job_detail_results.dart';

/// The open task: what it asks the assistant to do, when it runs, how the last
/// run went — and the three things you can do to it.
class JobDetail extends ConsumerWidget {
  const JobDetail({super.key, required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(right: 4),
      children: [
        _DetailHeader(job: job),
        const SizedBox(height: 16),
        // Results first: people open a task to see what it found, not to re-read
        // the prompt they wrote. The instructions and schedule sit below it.
        _Results(job: job),
        const SizedBox(height: 18),
        _Actions(job: job),
        const SizedBox(height: 24),
        _SectionLabel(text: 'What it does'),
        const SizedBox(height: 10),
        _SoftPanel(
          padding: const EdgeInsets.all(16),
          child: Text(
            job.prompt,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ),
        const SizedBox(height: 18),
        _Facts(job: job),
      ],
    );
  }
}

/// The task's name and its state, together at the top — the same word the list
/// row shows, so opening a task confirms rather than surprises.
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = jobStatusOf(job);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            job.name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(width: 10),
        StatusPill(
          label: jobStatusLabel(status),
          color: jobStatusColor(status),
        ),
      ],
    );
  }
}

/// A small uppercase divider label for the lower, reference part of the pane.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppPalette.textFaint,
      ),
    );
  }
}

class _SoftPanel extends StatelessWidget {
  const _SoftPanel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
