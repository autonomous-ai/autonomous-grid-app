import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/glass_card.dart';

/// One card in a project's right rail: an icon-led title, an optional trailing
/// action, and the card's body.
///
/// Every rail card is built from this so they line up and share the same chrome,
/// spacing, and header treatment — the rail reads as one column, not four
/// unrelated boxes.
class RailCard extends StatelessWidget {
  const RailCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;

  /// A single header action (an edit pencil, an add button), flush right of the
  /// title. Icon-only actions must carry their own tooltip.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 13, 10, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppPalette.textSecondary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: AppFont.semibold,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 11),
          child,
        ],
      ),
    );
  }
}

/// The quiet placeholder line a rail card shows when it has nothing yet — a
/// small piece of guidance in the card's faint tone, so an empty card still
/// tells the user what it's for.
class RailHint extends StatelessWidget {
  const RailHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint, height: 1.4),
    );
  }
}
