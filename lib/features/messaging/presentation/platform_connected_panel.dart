part of 'messages_view.dart';

/// A bot is connected. Two facts, in this order: whether it's actually
/// answering, and who it answers.
class PlatformConnectedPanel extends ConsumerWidget {
  const PlatformConnectedPanel({
    super.key,
    required this.platform,
    required this.allowedUsers,
    required this.link,
    this.detail,
  });

  final MessagingPlatform platform;
  final List<String> allowedUsers;
  final MessagingLink link;
  final String? detail;

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
    final controller = ref.read(messagingProvider(platform).notifier);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Status(
              link: link,
              detail: detail,
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
                    Icon(
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

/// Connected and *answering* are different things — a bot whose gateway is down,
/// or whose token another process is polling, answers nobody. This reads the
/// real link state from Hermes, so it never says "Answering" when it isn't.
class _Status extends StatelessWidget {
  const _Status({
    required this.link,
    required this.detail,
    required this.onStart,
  });

  final MessagingLink link;
  final String? detail;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:color, :icon, :title, :body) = _describe();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            // Only "not answering" is the user's to fix — connecting resolves on
            // its own, and answering needs no action.
            if (link == MessagingLink.notAnswering) ...[
              const SizedBox(width: 12),
              FilledButton(onPressed: onStart, child: const Text('Turn it on')),
            ],
          ],
        ),
      ),
    );
  }

  ({Color color, IconData icon, String title, String body}) _describe() {
    return switch (link) {
      MessagingLink.answering => (
        color: AppPalette.online,
        icon: Icons.check_circle_rounded,
        title: 'Answering your messages',
        body: 'It stops when this computer sleeps or shuts down.',
      ),
      MessagingLink.connecting => (
        color: AppPalette.textSecondary,
        icon: Icons.sync_rounded,
        title: 'Connecting…',
        body: 'Bringing the bot online — this takes a moment.',
      ),
      MessagingLink.notAnswering => (
        color: AppPalette.warn,
        icon: Icons.pause_circle_outline_rounded,
        title: 'Not answering',
        body: detail ?? 'The bot is set up, but nothing is listening yet.',
      ),
    };
  }
}
