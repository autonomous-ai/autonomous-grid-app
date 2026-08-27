import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// A lifted pill action for a developer tab's toolbar — the button shape used
/// across the reference tabs (fill + shadow, no border, radius 11).
///
/// Shared by Debug and Tracking rather than copied into each: the two toolbars
/// sit one row apart in the same nav group, and two buttons that are meant to
/// look identical drift the moment only one of them is edited.
///
/// A null [onPressed] draws it disabled — which is why this isn't
/// [SoftActionButton], whose callback is required: "Clear" has to be visible
/// and dead when there is nothing to clear.
class DebugToolbarButton extends StatefulWidget {
  const DebugToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<DebugToolbarButton> createState() => _DebugToolbarButtonState();
}

class _DebugToolbarButtonState extends State<DebugToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppGlass/AppPalette tokens.
    final enabled = widget.onPressed != null;
    // Glyph climbs to full color on hover; drops back and dims when disabled.
    final fg = !enabled
        ? AppPalette.textFaint
        : _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;
    return Material(
      color: AppGlass.surfaceFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: widget.onPressed,
        onHover: (v) => setState(() => _hovered = v),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 16, color: fg),
              const SizedBox(width: 8),
              // A button's label — see `unselectableLabel`.
              SelectionContainer.disabled(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
