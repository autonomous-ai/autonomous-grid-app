part of 'telegram_view.dart';

/// Connecting a bot, in the three steps it actually takes — and the one thing
/// that keeps it yours: the list of who may message it.
class TelegramConnectForm extends ConsumerStatefulWidget {
  const TelegramConnectForm({super.key});

  @override
  ConsumerState<TelegramConnectForm> createState() =>
      _TelegramConnectFormState();
}

class _TelegramConnectFormState extends ConsumerState<TelegramConnectForm> {
  final _token = TextEditingController();
  final _userId = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    _userId.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await ref
        .read(telegramProvider.notifier)
        .connect(token: _token.text, userId: _userId.text);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Step(
              number: 1,
              title: 'Make a bot',
              detail:
                  'In Telegram, message @BotFather and send /newbot. It gives '
                  'you a token — a long line starting with numbers.',
            ),
            const _Step(
              number: 2,
              title: 'Find your Telegram id',
              detail:
                  'Message @userinfobot. It replies with your id, a number. '
                  'Only the people you list here can use your bot.',
            ),
            const _Step(
              number: 3,
              title: 'Paste them in',
              detail: 'Then the bot answers you, from this computer.',
            ),
            const SizedBox(height: 18),
            _Field(
              controller: _token,
              label: 'Bot token',
              hint: '8123456789:AAF…',
              obscure: true,
            ),
            const SizedBox(height: 12),
            _Field(
              controller: _userId,
              label: 'Your Telegram id',
              hint: '123456789',
            ),
            const SizedBox(height: 16),
            const _Honesty(),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _connecting ? null : _connect,
                child: Text(_connecting ? 'Connecting…' : 'Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the user is actually turning on. Said before they turn it on, not after.
class _Honesty extends StatelessWidget {
  const _Honesty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in const [
              'Only the ids you list can message the bot. Anyone else is '
                  'ignored.',
              'A message runs the assistant on this computer — the same one, '
                  'with the same access to your project files.',
              "It goes quiet when this computer sleeps or shuts down. It isn't "
                  'a bot in the cloud.',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        line,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.detail,
  });

  final int number;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: AppPalette.cardBg,
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}
