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
            const SizedBox(height: 24),
            for (final field in platform.credentials) ...[
              _Field(
                controller: _fields[field.envKey]!,
                label: field.label,
                hint: field.hint,
                obscure: true,
              ),
              const SizedBox(height: 16),
            ],
            _Field(
              controller: _userId,
              label: platform.userIdLabel,
              hint: platform.userIdHint,
            ),
            const SizedBox(height: 24),
            _Honesty(platform: platform),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _connecting ? null : _connect,
                // A spinner in the button, not just a word — the label alone
                // left "Connecting…" looking like a disabled button.
                child: _connecting
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppSpinner.onAccent(size: SpinnerSize.small),
                          SizedBox(width: 8),
                          Text('Connecting…'),
                        ],
                      )
                    : const Text('Connect'),
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
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final lines = [
      'Only the ids you list can message the bot. Anyone else is ignored.',
      'A message runs the assistant on this computer — it can read and edit '
          'files in your projects and look things up on the web, but from '
          "${platform.label} it can't run terminal commands or programs.",
      "It goes quiet when this computer sleeps or shuts down. It isn't a bot in "
          'the cloud.',
      'Connecting turns on a small background program that listens for your '
          'messages. It starts up with this computer; disconnecting stops the '
          'bot answering, but leaves that program running.',
    ];
    // Neither GlassCard style fits this one. `card` carries the indigo wash,
    // aura and top hairline, and on a block of *caveats* that pulled more
    // attention than the token fields above it. `inset` is the calm recess this
    // wants, but it's built to sit *inside* a card — directly on the page it
    // lands at 1.02:1 in light and effectively disappears.
    //
    // So: the neutral raised surface plus the shared lift. Fill alone separates
    // by only ~1.1:1 here; the shadow is what actually does the layering.
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(AppCard.radius),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
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
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
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

class _Step extends StatelessWidget {
  const _Step({required this.step});

  final ConnectStep step;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A recess, not a card: the number sits *into* the page rather than
          // floating above it, and AppCard.inset is what reads as sunk in both
          // themes.
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppCard.inset,
              shape: BoxShape.circle,
            ),
            child: Text(
              '${step.number}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
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

/// A secret or an id, labelled the app's way: the label sits still above the
/// field rather than floating into its rim.
///
/// Not [LabeledField] itself because a token field obscures its text, which that
/// widget doesn't take — so it's built from the same two pieces [LabeledField]
/// is, and matches it exactly.
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
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontSize: 14, height: 1.4),
          decoration: labeledFieldDecoration(hint),
        ),
      ],
    );
  }
}
