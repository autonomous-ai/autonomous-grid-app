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
    final message = error == null ? done : describeCronRunError(error).summary;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
          style: _filledStyle(),
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
          style: _outlinedStyle(),
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
            minimumSize: const Size(96, 34),
            textStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          label: const Text('Delete'),
        ),
      ],
    );
  }

  ButtonStyle _filledStyle() => FilledButton.styleFrom(
    minimumSize: const Size(124, 34),
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
  );

  ButtonStyle _outlinedStyle() => OutlinedButton.styleFrom(
    minimumSize: const Size(106, 34),
    shape: const StadiumBorder(),
    side: BorderSide(color: AppPalette.divider),
    textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
  );
}
