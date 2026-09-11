part of 'messages_view.dart';

/// A bot is connected. Two facts, in this order: whether it's actually
/// answering, and who it answers.
class PlatformConnectedPanel extends ConsumerWidget {
  const PlatformConnectedPanel({
    super.key,
    required this.platform,
    required this.connected,
  });

  final MessagingPlatform platform;
  final MessagingConnected connected;

  Future<void> _act(
    BuildContext context,
    Future<String?> Function() action,
  ) async {
    final error = await action();
    if (error == null || !context.mounted) return;
    ToastScope.show(
      context,
      ToastSpec(message: error, severity: ToastSeverity.error),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final actions = ref.read(messagingActionsProvider(platform));
    final theme = Theme.of(context);
    final note = connected.note;

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Status(
              connected: connected,
              platform: platform,
              onStart: () => _act(context, actions.start),
            ),
            if (note != null) ...[
              const SizedBox(height: 12),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Who can message it',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            // The allowlist is the one thing keeping the bot yours, so the ids
            // sit on a surface of their own rather than loose on the page. Same
            // recipe as the status card above: an inset would be the natural
            // choice, but it's built to sit inside a card and lands at 1.02:1
            // directly on the page.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppGlass.surfaceFill,
                borderRadius: BorderRadius.circular(AppCard.radius),
                boxShadow: AppGlass.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final id in connected.allowedUsers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
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
                ],
              ),
            ),
            const SizedBox(height: 8),
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
                onPressed: () => _act(context, actions.disconnect),
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

/// Connected and *answering* are different things — a bot whose poll or
/// gateway is down, or whose token another program is polling, answers nobody.
/// This reads the real link state, so it never says "Answering" when it isn't.
class _Status extends StatelessWidget {
  const _Status({
    required this.connected,
    required this.platform,
    required this.onStart,
  });

  final MessagingConnected connected;
  final MessagingPlatform platform;
  final VoidCallback onStart;

  MessagingLink get link => connected.link;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final (:color, :icon, :title, :body) = _describe();

    // Not a GlassCard in either style: `hero` and `card` both lay an indigo wash
    // (hero's is merely stronger), and this card's whole job is to signal status
    // in green or amber. Two colour stories in one box muddies the one signal
    // the user came here to read. The neutral raised surface plus the shared
    // lift keeps the status colour the only colour in the box.
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(AppCard.radius),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Row(
        children: [
          // "Connecting" is a live state, so it gets the app's one heartbeat
          // rather than a static glyph that looks stuck.
          if (link == MessagingLink.connecting)
            const AppSpinner(size: SpinnerSize.medium)
          else
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
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
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
    );
  }

  ({Color color, IconData icon, String title, String body}) _describe() {
    return switch (link) {
      MessagingLink.answering => (
        color: AppPalette.online,
        icon: Icons.check_circle_rounded,
        title: 'Answering your messages',
        body: _answeringBody(),
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
        body:
            connected.detail ??
            'The bot is set up, but nothing is listening yet.',
      ),
    };
  }

  /// Where to find the bot, then when it stops — which depends on what runs it.
  String _answeringBody() {
    final handle = connected.handle;
    final find = handle == null ? '' : 'Message $handle on ${platform.label}. ';
    return switch (connected.host) {
      MessagingHost.grid =>
        '${find}It stops when Grid closes or this computer '
            'sleeps.',
      MessagingHost.hermes =>
        '${find}It stops when this computer sleeps or '
            'shuts down.',
    };
  }
}
