import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's one way of saying "we have a place for this, but it isn't built".
///
/// A bordered pill in the quiet ink — deliberately unlike the status dots that
/// report live state. "Offline" means something broke; this means it was never
/// switched on, and the two must not look alike.
///
/// Pair it with withholding the controls, and stop there: dimming the row on top
/// of both says the same thing a third time, and it dims the explanatory text
/// along with it.
class NotYetBadge extends StatelessWidget {
  const NotYetBadge({super.key, this.label = 'Not available yet'});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFont.medium,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
