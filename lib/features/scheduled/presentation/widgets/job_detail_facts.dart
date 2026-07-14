part of 'job_detail.dart';

class _Facts extends StatelessWidget {
  const _Facts({required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context) {
    return _SoftPanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          _FactRow(label: 'Runs', value: describeJobCron(job.cron)),
          _FactRow(
            label: 'State',
            value: job.enabled ? 'Running to schedule' : 'Paused',
          ),
          _FactRow(label: 'Next run', value: _when(job.nextRunAt, job.enabled)),
          _FactRow(label: 'Last run', value: _lastRun(job)),
          if (job.failed)
            _FactRow(label: 'Last error', value: job.lastError!, warn: true),
        ],
      ),
    );
  }

  static String _when(DateTime? time, bool enabled) {
    if (!enabled) return 'Paused — nothing scheduled';
    if (time == null) return 'Not scheduled yet';
    return jobTimeLabel(time);
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
  const _FactRow({required this.label, required this.value, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: warn ? theme.colorScheme.error : AppPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
