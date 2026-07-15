import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../../shared/layouts/shell_state.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../logic/job_schedule.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';
import '../../logic/task_delivery.dart';

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
        Text(
          job.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 14),
        _SoftPanel(
          padding: const EdgeInsets.all(16),
          child: Text(
            job.prompt,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ),
        const SizedBox(height: 18),
        _Facts(job: job),
        const SizedBox(height: 22),
        _Results(job: job),
        const SizedBox(height: 18),
        _Actions(job: job),
      ],
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
