import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// The grid's initial in a tinted tile — a fast visual anchor when switching
/// between grids, so the eye catches "wrong grid" before reading the name.
class GridMonogram extends StatelessWidget {
  const GridMonogram({
    super.key,
    required this.name,
    this.size = 26,
    this.muted = false,
  });

  final String name;

  /// The tile's side. 26 heads the card, 18 rides inside a chip.
  final double size;

  /// Neutral instead of accent, for a grid that can only be consumed from — the
  /// accent is how this page marks somewhere you can actually serve.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first;
    final color = muted ? AppPalette.textSecondary : AppPalette.accentOnSurface;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? AppSurface.wellFill : color.withValues(alpha: 0.13),
        // Proportional, so the small tile rounds the same amount to the eye as
        // the 26px one does at radius 7.
        borderRadius: BorderRadius.circular(size * 0.27),
      ),
      child: Text(
        initial.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: size < 22 ? 10.5 : null,
        ),
      ),
    );
  }
}
