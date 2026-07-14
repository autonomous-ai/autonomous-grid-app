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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 34 : 66, 24, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Glyph(),
                  const SizedBox(height: 18),
                  Text(
                    greeting,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: compact ? 27 : 31,
                      fontWeight: FontWeight.w700,
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 30),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final starter in _starters)
                        _StarterCard(
                          starter: starter,
                          width: compact ? 158 : 170,
                          onTap: () => onPick(starter.prompt),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.cloud_outlined,
      size: 45,
      color: Color(0xFFB8B8B8),
      semanticLabel: 'Grid',
    );
  }
}

/// One thing the chat is good at, with the prompt it drops into the composer.
class _Starter {
  const _Starter({
    required this.icon,
    required this.color,
    required this.title,
    required this.prompt,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String prompt;
}

const _starters = [
  _Starter(
    icon: Icons.travel_explore_rounded,
    color: Color(0xFF2F80ED),
    title: 'Explore and understand code',
    prompt: 'Explore this code and explain how it works:\n\n',
  ),
  _Starter(
    icon: Icons.architecture_rounded,
    color: Color(0xFF8A3FFC),
    title: 'Build a new feature, app, or tool',
    prompt: 'Help me build a new feature, app, or tool: ',
  ),
  _Starter(
    icon: Icons.manage_search_rounded,
    color: Color(0xFF16A34A),
    title: 'Review code and suggest changes',
    prompt: 'Review this code and suggest changes:\n\n',
  ),
  _Starter(
    icon: Icons.local_fire_department_outlined,
    color: Color(0xFFF97316),
    title: 'Fix a bug or failure',
    prompt: 'Help me debug this issue:\n\n',
  ),
];

/// One tappable suggestion card.
class _StarterCard extends StatefulWidget {
  const _StarterCard({
    required this.starter,
    required this.width,
    required this.onTap,
  });

  final _Starter starter;
  final double width;
  final VoidCallback onTap;

  @override
  State<_StarterCard> createState() => _StarterCardState();
}

class _StarterCardState extends State<_StarterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    // On hover the card lifts: it tints its rim to the starter's own colour,
    // deepens the shadow, and rises a couple of pixels — so it reads as a real,
    // pickable surface instead of a ghost on the near-white pane.
    final borderColor = _hovered
        ? widget.starter.color.withValues(alpha: 0.55)
        : AppGlass.hair;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        // Rise on hover — a paint transform, so neighbours never shift.
        transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppCard.base,
          borderRadius: radius,
          // Rim stays 1.5px at rest and on hover — only its colour animates, so
          // the content never nudges by the half-pixel a width change would add.
          border: Border.all(color: borderColor, width: 1.5),
          boxShadow: _hovered ? AppCard.shadow : AppGlass.cardShadow,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            hoverColor: Colors.transparent,
            child: SizedBox(
              width: widget.width,
              height: 112,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
                child: _StarterContent(
                  starter: widget.starter,
                  hovered: _hovered,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StarterContent extends StatelessWidget {
  const _StarterContent({required this.starter, required this.hovered});

  final _Starter starter;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The icon sits in a soft tinted chip — a small spot of the starter's
        // colour that gives each card a point of focus and lifts it off white.
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: starter.color.withValues(alpha: hovered ? 0.18 : 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(starter.icon, size: 17, color: starter.color),
        ),
        const Spacer(),
        Text(
          starter.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.12,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
      ],
    );
  }
}
