import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A compact Codex-like segmented pill used by desktop toolbar controls.
class PillChoice extends StatelessWidget {
  const PillChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.height = 34,
  });

  final Widget label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    // Follow theme flips: an unselected pill is often built inside a `const`-ish
    // toolbar loop with no runtime arg to force a rebuild, so without watching it
    // stays on one theme's surface color (a dark chip left on a light page). See
    // AppTheme.watch.
    AppTheme.watch(context);
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : AppGlass.surfaceFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected ? AppGlass.cardShadow : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 8),
              ],
              // A pill is a button, so what is written on it is a label and not
              // the page's text — the rule `unselectableLabel` applies to every
              // Material button. This one is built from an `InkWell`, so no
              // `ButtonStyle` reaches it and it has to say so itself.
              SelectionContainer.disabled(
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13.5,
                    fontWeight: AppFont.medium,
                  ),
                  child: label,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
