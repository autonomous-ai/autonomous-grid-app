import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/liquid_glass.dart';

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
          padding: EdgeInsets.fromLTRB(24, compact ? 36 : 68, 24, 28),
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
                      fontSize: compact ? 26 : 30,
                      fontWeight: FontWeight.w500,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 32),
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
    final radius = BorderRadius.circular(13);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.015 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: LiquidGlass(
          borderRadius: radius,
          fill: _hovered ? AppGlass.surfaceHoverFill : AppGlass.surfaceFill,
          showShadow: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.onTap,
              child: SizedBox(
                width: widget.width,
                height: 110,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
                  child: _StarterContent(starter: widget.starter),
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
  const _StarterContent({required this.starter});

  final _Starter starter;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(starter.icon, size: 18, color: starter.color),
        const Spacer(),
        Text(
          starter.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: AppPalette.textPrimary,
          ),
        ),
      ],
    );
  }
}
