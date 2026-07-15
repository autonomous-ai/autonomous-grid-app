import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    // Reads AppPalette tokens (the subtitle) — follow theme flips.
    AppTheme.watch(context);
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
                  const SizedBox(height: 20),
                  Text(
                    greeting,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: compact ? 27 : 31,
                      fontWeight: FontWeight.w700,
                      height: 1.06,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Pick a starting point, or just start typing.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.3,
                      color: AppPalette.textSecondary,
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
                          width: compact ? 166 : 178,
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
    // Follow the theme so this mark re-tints on a Light/Dark flip.
    AppTheme.watch(context);
    // The brand bolt in a soft indigo→violet chip — Grid's own mark, and the one
    // spot of colour up here. A grey cloud said nothing about code; the bolt ties
    // the greeting to the app and gives the empty state a warm focal point.
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppPalette.accent,
            Color.lerp(AppPalette.accent, const Color(0xFF7A3CF0), 0.5)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppPalette.accent.withValues(alpha: 0.38),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: -8,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(
        LucideIcons.zap,
        size: 25,
        color: Colors.white,
        semanticLabel: 'Grid',
      ),
    );
  }
}

/// One thing the chat is good at, with the prompt it drops into the composer.
class _Starter {
  const _Starter({
    required this.icon,
    required this.lightColor,
    required this.darkColor,
    required this.title,
    required this.description,
    required this.prompt,
  });

  final IconData icon;

  /// The accent colours, per surface — the dark values are lifted so the chip and
  /// icon keep their contrast on charcoal instead of muddying.
  final Color lightColor;
  final Color darkColor;
  final String title;

  /// A quiet second line under the title — says what the card actually does, so
  /// each one reads as an offer rather than just a label.
  final String description;
  final String prompt;

  /// The starter's accent for the live theme.
  Color get color => AppTheme.pick(lightColor, darkColor);
}

const _starters = [
  _Starter(
    icon: LucideIcons.searchCode,
    lightColor: Color(0xFF2F80ED),
    darkColor: Color(0xFF5B9BF5),
    title: 'Explore & understand code',
    description: 'Walk through how it works',
    prompt: 'Explore this code and explain how it works:\n\n',
  ),
  _Starter(
    icon: LucideIcons.draftingCompass,
    lightColor: Color(0xFF8A3FFC),
    darkColor: Color(0xFFA66CFF),
    title: 'Build a feature or app',
    description: 'Start something new',
    prompt: 'Help me build a new feature, app, or tool: ',
  ),
  _Starter(
    icon: LucideIcons.scanSearch,
    lightColor: Color(0xFF16A34A),
    darkColor: Color(0xFF35C46B),
    title: 'Review & suggest changes',
    description: 'Get a second pair of eyes',
    prompt: 'Review this code and suggest changes:\n\n',
  ),
  _Starter(
    icon: LucideIcons.bug,
    lightColor: Color(0xFFF97316),
    darkColor: Color(0xFFFB9A4B),
    title: 'Fix a bug or failure',
    description: 'Track down what broke',
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
    // Reads AppCard/AppGlass tokens — follow theme flips even when not hovering.
    AppTheme.watch(context);
    final radius = BorderRadius.circular(16);
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
              height: 128,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
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
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The icon sits in a soft tinted chip — a small spot of the starter's
            // colour that gives each card a point of focus and lifts it off the
            // pane. It swells a hair on hover so the card feels responsive.
            AnimatedScale(
              scale: hovered ? 1.06 : 1,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: Alignment.topLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: starter.color.withValues(alpha: hovered ? 0.20 : 0.13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(starter.icon, size: 18, color: starter.color),
              ),
            ),
            const Spacer(),
            Text(
              starter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.16,
                letterSpacing: -0.1,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 3),
            // The quiet second line — hidden on the narrowest cards where the
            // title may wrap to two lines, so the two never collide.
            Text(
              starter.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ),
        // A directional cue that fades in on hover: this card takes you somewhere
        // (it prefills the composer). Tinted to the starter's own colour.
        Positioned(
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: Offset(hovered ? 0 : -0.25, 0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: hovered ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: Icon(
                LucideIcons.arrowRight,
                size: 15,
                color: starter.color,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
