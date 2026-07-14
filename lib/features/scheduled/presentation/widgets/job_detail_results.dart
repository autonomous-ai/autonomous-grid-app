part of 'job_detail.dart';

/// How much of the latest result to show here. It's a peek, not the place to read
/// it — that's the chat, where the whole thread of runs lives.
const int _previewLines = 8;

/// What the task has actually produced.
///
/// A scheduled task that runs and leaves its answer in a file the user never
/// opens is a task that did nothing. Every run is delivered into the task's own
/// chat; this shows the latest one and takes you there.
class _Results extends ConsumerWidget {
  const _Results({required this.job});

  final ScheduledJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final runs = ref.watch(jobOutputsProvider(job.id));
    final delivered = runs.asData?.value ?? const <CronOutput>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Results',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (delivered.isNotEmpty)
              TextButton.icon(
                onPressed: () => _openInChat(ref),
                icon: const Icon(Icons.forum_outlined, size: 16),
                label: Text(
                  'Open in chat (${delivered.length})',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        switch (runs) {
          AsyncData(:final value) when value.isEmpty => const _NoResults(),
          AsyncData(:final value) => _LatestResult(run: value.last),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read what this task produced: $error",
          ),
          _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        },
      ],
    );
  }

  /// Open the task's chat, delivering anything that landed since the last sweep
  /// first — so the chat is never a step behind the panel that linked to it.
  Future<void> _openInChat(WidgetRef ref) async {
    await ref.read(taskDeliveryProvider.notifier).sweep();
    ref.read(chatSessionsProvider.notifier).select(taskConversationId(job.id));
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }
}

/// The most recent run: when it was, and the top of what it said.
class _LatestResult extends StatelessWidget {
  const _LatestResult({required this.run});

  final CronOutput run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = run.text.split('\n');
    final preview = lines.take(_previewLines).join('\n');
    final more = lines.length - _previewLines;

    return _SoftPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            jobTimeLabel(run.at),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textFaint,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            preview,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
          if (more > 0) ...[
            const SizedBox(height: 8),
            Text(
              '… $more more ${more == 1 ? 'line' : 'lines'} — read it in chat',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// It hasn't produced anything yet — say which of the two reasons it is, since
/// they need different things from the user.
class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return _SoftPanel(
      padding: const EdgeInsets.all(16),
      child: Text(
        "Nothing yet. When this task runs, its answer arrives in a chat of its "
        'own — you never have to go looking for it.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
      ),
    );
  }
}
