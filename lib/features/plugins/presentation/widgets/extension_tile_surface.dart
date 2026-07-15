import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// A quiet Codex-like list tile surface for plugin and skill rows.
class ExtensionTileSurface extends StatelessWidget {
  const ExtensionTileSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppGlass tokens.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
        child: child,
      ),
    );
  }
}

/// A small leading icon well for plugin and skill rows.
class ExtensionIconBadge extends StatelessWidget {
  const ExtensionIconBadge({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 16, color: AppPalette.textSecondary),
    );
  }
}

/// A compact metadata tag shown beside plugin and skill names.
class ExtensionTag extends StatelessWidget {
  const ExtensionTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppCard tokens.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppCard.accentStrong,
        ),
      ),
    );
  }
}
