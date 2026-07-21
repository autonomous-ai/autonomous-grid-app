part of 'messages_view.dart';

/// Connecting a bot for one platform, in the steps it takes — and the one thing
/// that keeps it yours: the list of who may message it.
class PlatformConnectForm extends ConsumerStatefulWidget {
  const PlatformConnectForm({super.key, required this.platform});

  final MessagingPlatform platform;

  @override
  ConsumerState<PlatformConnectForm> createState() =>
      _PlatformConnectFormState();
}

class _PlatformConnectFormState extends ConsumerState<PlatformConnectForm> {
  /// One controller per credential the platform asks for, keyed by its `.env`
  /// key so [connect] can hand the notifier a value for each.
  late final Map<String, TextEditingController> _fields;
  final _userId = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fields = {
      for (final field in widget.platform.credentials)
        field.envKey: TextEditingController(),
    };
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _userId.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await ref
        .read(messagingProvider(widget.platform).notifier)
        .connect(
          credentials: {
            for (final entry in _fields.entries) entry.key: entry.value.text,
          },
          userId: _userId.text,
        );
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform;
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final step in platform.steps) _Step(step: step),
            const SizedBox(height: 18),
            for (final field in platform.credentials) ...[
              _Field(
                controller: _fields[field.envKey]!,
                label: field.label,
                hint: field.hint,
                obscure: true,
              ),
              const SizedBox(height: 12),
            ],
            _Field(
              controller: _userId,
              label: platform.userIdLabel,
              hint: platform.userIdHint,
            ),
            const SizedBox(height: 16),
            _Honesty(platform: platform),
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
  const _Honesty({required this.platform});

  final MessagingPlatform platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = [
      'Only the ids you list can message the bot. Anyone else is ignored.',
      'A message runs the assistant on this computer — it can read and edit '
          "files in your projects, but from ${platform.label} it can't run "
          'terminal commands or programs.',
      "It goes quiet when this computer sleeps or shuts down. It isn't a bot in "
          'the cloud.',
      'Connecting turns on a small background program that listens for your '
          'messages. It starts up with this computer; disconnecting stops the '
          'bot answering, but leaves that program running.',
    ];
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
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
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
  const _Step({required this.step});

  final ConnectStep step;

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
              '${step.number}',
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
                  step.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  step.detail,
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
