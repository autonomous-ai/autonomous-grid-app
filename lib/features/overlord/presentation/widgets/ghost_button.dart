import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../overlord_tokens.dart';

/// A compact bordered button in the dashboard idiom — used for chrome actions
/// (Reset layout, Sign out) and panel header actions (Fullscreen, Restart).
/// A null [onPressed] renders it as an inert (placeholder) control.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.cardBg,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: AppPalette.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: AppPalette.textSecondary),
                const SizedBox(width: 6),
              ],
              // A button's label — see `unselectableLabel`.
              SelectionContainer.disabled(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: OverlordTokens.mono,
                    fontFamilyFallback: OverlordTokens.monoFallback,
                    fontSize: 12,
                    color: AppPalette.textSecondary,
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
