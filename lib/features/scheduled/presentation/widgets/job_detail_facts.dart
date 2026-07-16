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
          if (job.failed) _errorRow(job.lastError!),
        ],
      ),
    );
  }

  static Widget _errorRow(String raw) {
    final error = describeCronRunError(raw);
    return _FactRow(
      label: 'Last error',
      value: error.summary,
      hint: error.hint,
      warn: true,
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
