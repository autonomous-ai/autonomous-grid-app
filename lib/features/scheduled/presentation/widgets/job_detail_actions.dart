part of 'job_detail.dart';

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
    ToastScope.showResult(
      context,
      error: error == null ? null : describeCronRunError(error).summary,
      success: done,
    );
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
      spacing: 9,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _do(
                  (c) => c.runNow(job.id),
                  'Running it now — the answer lands in a moment.',
                ),
          icon: const Icon(Icons.play_arrow_rounded, size: AppControl.iconSize),
          label: const Text('Run now'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => showEditJobDialog(context, job),
          icon: const Icon(Icons.edit_outlined, size: AppControl.iconSize),
          label: const Text('Edit'),
        ),
        // Only for a task the scheduler is skipping because the model moved on:
        // it's the one failure the user can clear from here, and offering it on a
        // healthy task would ask them to fix something that isn't broken.
        if (job.failed && isModelDriftSkip(job.lastError!))
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _do(
                    (c) => c.useCurrentModel(job.id),
                    'Back on schedule — it will run with your current AI model.',
                  ),
            icon: const Icon(
              Icons.autorenew_rounded,
              size: AppControl.iconSize,
            ),
            label: const Text('Use the current model'),
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
            size: AppControl.iconSize,
          ),
          label: Text(job.enabled ? 'Pause' : 'Resume'),
        ),
        // The only style left: Delete earns the error colour. Everything else
        // (height, shape, label) comes from the app's button themes.
        TextButton.icon(
          onPressed: _busy ? null : _confirmDelete,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          icon: const Icon(
            Icons.delete_outline_rounded,
            size: AppControl.iconSize,
          ),
          label: const Text('Delete'),
        ),
      ],
    );
  }
}
