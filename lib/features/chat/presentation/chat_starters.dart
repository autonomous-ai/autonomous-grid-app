import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// A fresh chat's empty state: a greeting and four things to try. Tapping one
/// drops its prompt into the composer, so a first-time user has something to send
/// instead of a blank box and a blinking cursor.
class ChatStarters extends StatelessWidget {
  const ChatStarters({super.key, required this.greeting, required this.onPick});

  final String greeting;

  /// Called with the tapped starter's prompt, to prefill the composer.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bolt_rounded,
                size: 34,
                color: AppPalette.textFaint,
                semanticLabel: 'Grid',
              ),
              const SizedBox(height: 16),
              Text(
                greeting,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              // Wrap, not a Row: on a narrow window the cards reflow onto a
              // second line instead of overflowing.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final starter in _starters)
                    _StarterCard(
                      starter: starter,
                      onTap: () => onPick(starter.prompt),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One thing the chat is good at, with the prompt it drops into the composer.
class _Starter {
  const _Starter({
    required this.icon,
    required this.title,
    required this.prompt,
  });

  final IconData icon;
  final String title;
  final String prompt;
}

const _starters = [
  _Starter(
    icon: Icons.lightbulb_outline_rounded,
    title: 'Explain something',
    prompt: 'Explain in plain language: ',
  ),
  _Starter(
    icon: Icons.edit_note_rounded,
    title: 'Write a draft',
    prompt: 'Write a first draft of ',
  ),
  _Starter(
    icon: Icons.code_rounded,
    title: 'Help with code',
    prompt: 'Help me with this code:\n\n',
  ),
  _Starter(
    icon: Icons.auto_awesome_outlined,
    title: 'Brainstorm ideas',
    prompt: 'Give me ten ideas for ',
  ),
];

/// One tappable suggestion card.
class _StarterCard extends StatefulWidget {
  const _StarterCard({required this.starter, required this.onTap});

  final _Starter starter;
  final VoidCallback onTap;

  @override
  State<_StarterCard> createState() => _StarterCardState();
}

class _StarterCardState extends State<_StarterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered ? AppPalette.cardBg : Colors.white,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onTap,
          child: Container(
            width: 168,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: AppPalette.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.starter.icon, size: 18, color: AppPalette.accent),
                const SizedBox(height: 14),
                Text(
                  widget.starter.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
