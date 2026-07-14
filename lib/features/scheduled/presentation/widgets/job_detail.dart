import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../logic/job_schedule.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';

/// The open task: what it asks the assistant to do, when it runs, how the last
/// run went — and the three things you can do to it.
class JobDetail extends ConsumerWidget {
  const JobDetail({super.key, required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(left: 20),
      children: [
        Text(
          job.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 14),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Text(job.prompt, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 18),
        _Facts(job: job),
        const SizedBox(height: 18),
        _Actions(job: job),
      ],
    );
  }
}

/// When it runs, when it last ran, and what came of it. A failed run says so —
/// silently rescheduling a task that keeps erroring would be the worst outcome.
class _Facts extends StatelessWidget {
  const _Facts({required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      style: GlassCardStyle.inset,
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
    return _stamp(time);
  }

  static String _lastRun(ScheduledJob job) {
    final at = job.lastRunAt;
    if (at == null) return "Hasn't run yet";
    final status = job.failed
        ? 'failed'
        : (job.lastStatus ?? 'finished').toLowerCase();
    return '${_stamp(at)} — $status';
  }

  static String _stamp(DateTime time) {
    final d = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} at ${two(d.hour)}:${two(d.minute)}';
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

/// Run it now, pause / resume it, delete it. Each one waits on the scheduler and
/// says what happened, so a click never silently does nothing.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.job});

  final ScheduledJob job;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  Future<void> _do(
    Future<String?> Function(ScheduledJobsController) action,
    String done,
  ) async {
    setState(() => _busy = true);
    final error = await action(ref.read(scheduledJobsProvider.notifier));
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? done)));
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${widget.job.name}"?'),
        content: const Text("It won't run again. This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _do((c) => c.remove(widget.job.id), 'Task deleted.');
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _do(
                  (c) => c.runNow(job.id),
                  'Running it now — the answer lands in a moment.',
                ),
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Run now'),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => job.enabled
                    ? _do((c) => c.pause(job.id), 'Paused.')
                    : _do(
                        (c) => c.resume(job.id),
                        'Running to schedule again.',
                      ),
          icon: Icon(
            job.enabled ? Icons.pause_rounded : Icons.play_circle_outline,
            size: 18,
          ),
          label: Text(job.enabled ? 'Pause' : 'Resume'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _confirmDelete,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('Delete'),
        ),
      ],
    );
  }
}
