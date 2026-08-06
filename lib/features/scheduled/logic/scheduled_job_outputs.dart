import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_cron_service.dart';
import 'scheduled_jobs_controller.dart';
import 'task_delivery.dart';

/// What a task's runs have produced, oldest first — read back from Hermes, which
/// writes one file per run. Refetches whenever a sweep delivers something new, so
/// the screen and the chat never disagree about what the task has found.
final jobOutputsProvider = FutureProvider.family<List<CronOutput>, String>((
  ref,
  jobId,
) async {
  ref.watch(taskDeliveryProvider);
  final service = ref.watch(hermesCronServiceProvider);
  if (service == null) return const [];
  return service.readOutputs(jobId);
});

/// One finished run, tagged with the task it belongs to — the unit the "recent
/// activity" view is built from.
typedef JobRun = ({String jobId, String jobName, DateTime at, String text});

/// The latest runs across every task, newest first — what the right pane shows
/// before a task is picked, so an empty selection still proves the assistant is
/// working. Rebuilds whenever a sweep delivers something new.
final recentActivityProvider = FutureProvider<List<JobRun>>((ref) async {
  ref.watch(taskDeliveryProvider);
  final service = ref.watch(hermesCronServiceProvider);
  if (service == null) return const [];
  final jobs = await ref.watch(scheduledJobsProvider.future);

  final runs = <JobRun>[];
  for (final job in jobs) {
    for (final run in await service.readOutputs(job.id)) {
      runs.add((jobId: job.id, jobName: job.name, at: run.at, text: run.text));
    }
  }
  runs.sort((a, b) => b.at.compareTo(a.at));
  return runs;
});
