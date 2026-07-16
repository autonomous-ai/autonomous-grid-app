import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../overlord_tokens.dart';

/// Centered icon + text filler for a panel body — loading, error, empty, and
/// not-yet-built states all route through this so they read consistently.
class PanelMessage extends StatelessWidget {
  const PanelMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: AppPalette.textFaint),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: OverlordTokens.meta),
          ],
        ),
      ),
    );
  }
}
