part of 'job_detail.dart';

class _Facts extends ConsumerWidget {
  const _Facts({required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = jobStatusOf(job);
    return _SoftPanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          _FactRow(label: 'Runs', value: describeJobSchedule(job.cron)),
          _FactRow(label: 'Model', value: _model(job)),
          _FactRow(label: 'State', value: _state(status)),
          _FactRow(label: 'Next run', value: _when(job.nextRunAt, status)),
          _FactRow(label: 'Last run', value: _lastRun(job)),
          if (job.failed) _errorRow(ref, job.lastError!),
        ],
      ),
    );
  }

  /// Which model answers this task. A task the app created is pinned to one and
  /// says so; an older one follows whatever the computer is set to, and saying
  /// *that* is what explains why its answers can change without the user
  /// touching it.
  static String _model(ScheduledJob job) {
    final model = job.model;
    if (model == null) return 'Whatever this computer is set to';
    if (model == kAutoModelId) return 'Auto — the grid picks';
    return modelDisplayLabel(model);
  }

  static String _state(JobStatus status) => switch (status) {
    JobStatus.running => 'Running to schedule',
    JobStatus.lastRunFailed => 'Running to schedule',
    JobStatus.blocked => "Won't run until you fix it",
    JobStatus.paused => 'Paused',
  };

  /// The last failure in plain words — and, where the failure is about a grid
  /// rather than about the task, *which* grid.
  ///
  /// The task runs out of Hermes's config, not out of this screen, so the grid
  /// it reaches is read from there ([hermesPointedGridProvider]) instead of
  /// assumed to be the one on screen. Shown by name when this machine knows the
  /// grid, else by id — an id the user can still match against the grid list
  /// beats a sentence that quietly drops which grid it means.
  static Widget _errorRow(WidgetRef ref, String raw) {
    final pointed = ref.watch(hermesPointedGridProvider).asData?.value;
    final known = pointed == null
        ? null
        : ref.watch(sessionProvider).byName(pointed)?.name ?? pointed;
    final error = describeCronRunError(
      raw,
      taskGrid: known,
      currentGrid: ref.watch(selectedNetworkProvider)?.name,
    );
    return _FactRow(
      label: 'Last error',
      value: error.summary,
      hint: error.hint,
      warn: true,
    );
  }

  /// A blocked task is still "enabled" in the store, but it won't run — so the
  /// next-run row must not promise a time the scheduler is going to skip.
  static String _when(DateTime? time, JobStatus status) {
    switch (status) {
      case JobStatus.paused:
        return 'Paused — nothing scheduled';
      case JobStatus.blocked:
        return "Won't run until you fix it";
      case JobStatus.running:
      case JobStatus.lastRunFailed:
        if (time == null) return 'Not scheduled yet';
        return jobTimeLabel(time);
    }
  }

  static String _lastRun(ScheduledJob job) {
    final at = job.lastRunAt;
    if (at == null) return "Hasn't run yet";
    final status = job.failed
        ? 'failed'
        : (job.lastStatus ?? 'finished').toLowerCase();
    return '${jobTimeLabel(at)} — $status';
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.value,
    this.hint,
    this.warn = false,
  });

  final String label;
  final String value;

  /// An optional fainter second line under [value] — the "what to do next" for a
  /// warning row, kept visually subordinate to the summary above it.
  final String? hint;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = this.hint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: warn
                        ? theme.colorScheme.error
                        : AppPalette.textPrimary,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
