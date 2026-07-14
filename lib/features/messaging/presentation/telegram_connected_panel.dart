part of 'telegram_view.dart';

/// A bot is connected. Two facts, in this order: whether it's actually
/// answering, and who it answers.
class TelegramConnectedPanel extends ConsumerWidget {
  const TelegramConnectedPanel({
    super.key,
    required this.allowedUsers,
    required this.running,
  });

  final List<String> allowedUsers;
  final bool running;

  Future<void> _act(
    BuildContext context,
    Future<String?> Function() action,
  ) async {
    final error = await action();
    if (error == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(telegramProvider.notifier);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Status(
              running: running,
              onStart: () => _act(context, controller.start),
            ),
            const SizedBox(height: 18),
            Text(
              'Who can message it',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final id in allowedUsers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    const Icon(
                      Icons.person_outline_rounded,
                      size: 16,
                      color: AppPalette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(id, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Anyone else who finds the bot is ignored.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _act(context, controller.disconnect),
                icon: const Icon(Icons.link_off_rounded, size: 17),
                label: const Text('Disconnect this bot'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Connected and *listening* are different things — a bot whose gateway is down
/// answers nobody, and saying "connected" there would be a lie.
class _Status extends StatelessWidget {
  const _Status({required this.running, required this.onStart});

  final bool running;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = running ? AppPalette.online : AppPalette.warn;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              running
                  ? Icons.check_circle_rounded
                  : Icons.pause_circle_outline_rounded,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    running ? 'Answering your messages' : 'Not answering',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    running
                        ? 'It stops when this computer sleeps or shuts down.'
                        : 'The bot is set up, but nothing is listening for '
                              'messages.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (!running) ...[
              const SizedBox(width: 12),
              FilledButton(onPressed: onStart, child: const Text('Turn it on')),
            ],
          ],
        ),
      ),
    );
  }
}
