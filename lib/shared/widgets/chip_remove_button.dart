import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ✕ on a composer chip — takes one thing back off the message being
/// typed.
///
/// Shared by every kind of chip so they are the same size and the same weight:
/// a row holding a file and a terminal must not look like a row holding two
/// different controls.
class ChipRemoveButton extends StatelessWidget {
  const ChipRemoveButton({
    super.key,
    required this.onTap,
    required this.semanticLabel,
    this.size = 14,
  });

  final VoidCallback onTap;

  /// The glyph's size, so the ✕ stays in proportion on a chip that carries less
  /// than a file does — a terminal chip is a word, not a name and a file size.
  final double size;

  /// What a screen reader says — "Remove file", "Remove terminal". The tooltip
  /// stays the shorter "Remove", which is unambiguous beside the thing itself.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips
    final radius = BorderRadius.circular(7);
    return Tooltip(
      message: 'Remove',
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        splashFactory: NoSplash.splashFactory,
        hoverColor: AppSurface.hoverFill,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: size,
            color: AppPalette.textFaint,
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }
}
