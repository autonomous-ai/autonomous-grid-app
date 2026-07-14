import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'section_scaffold.dart';

/// A screen the app has a place for but hasn't built yet.
///
/// It says so plainly — a "Not available yet" badge and what it *will* do — so a
/// user who clicks it learns something instead of meeting a dead page they'll
/// keep re-checking. No buttons that don't work: nothing here pretends.
class ComingSoonView extends StatelessWidget {
  const ComingSoonView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.points,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  /// What it will let you do, one line each.
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionScaffold(
      title: title,
      subtitle: subtitle,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Icon(icon, size: 34, color: AppPalette.textFaint)),
              const SizedBox(height: 14),
              const Center(child: _NotYetBadge()),
              const SizedBox(height: 18),
              Text(
                "When it's ready, you'll be able to:",
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              for (final point in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Icon(
                          Icons.circle,
                          size: 5,
                          color: AppPalette.textFaint,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(point, style: theme.textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotYetBadge extends StatelessWidget {
  const _NotYetBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppPalette.divider),
      ),
      child: const Text(
        'Not available yet',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
