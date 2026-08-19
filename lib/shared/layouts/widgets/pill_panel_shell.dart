import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The glass box every panel hanging off the top bar's grid pill is drawn on.
///
/// Shared so the hardware panel and the three stat panels (members, nodes,
/// models) read as one family: four popovers open from the same capsule, and a
/// panel that invented its own rim or padding would look like a surface that
/// arrived from somewhere else.
class PillPanelSurface extends StatelessWidget {
  const PillPanelSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.surfaceFill,
          borderRadius: BorderRadius.circular(AppCard.radius),
          border: Border.all(color: AppGlass.hair),
          boxShadow: AppGlass.shadow,
        ),
        child: Padding(padding: const EdgeInsets.all(13), child: child),
      ),
    );
  }
}

/// One labelled figure in a pill panel: what it is on the left, the number and
/// its unit on the right.
///
/// Shared by the hardware panel's footer and the token panel for the same reason
/// [PillPanelSurface] is shared — two popovers open from the same capsule, and a
/// row that set its own sizes would read as a surface from somewhere else. The
/// figure is in tabular figures because these numbers refresh in place, and
/// digits of differing width make the row twitch on every poll.
class PillPanelStatRow extends StatelessWidget {
  const PillPanelStatRow({
    super.key,
    required this.label,
    required this.value,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: 4),
            Text(
              unit!,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small accent chip on a row — what this one *is*, where the rest of the row
/// says what it holds: a subscription seat's tier, the grid's owner.
///
/// Shared for the same reason as everything else in this file: it started as a
/// private badge in the hardware panel, and the members list wanted the same
/// shape. Two copies of a ten-line chip drift in exactly the way a reader
/// notices — one radius, one tint — while both claim to mean "this row is
/// special".
///
/// Deliberately quiet. A chip is a label, not a warning, so it borrows the
/// accent at low alpha rather than a status colour: a roster where the owner's
/// row looked like an error would be worse than one with no mark at all.
class PillPanelBadge extends StatelessWidget {
  const PillPanelBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: AppPalette.accent,
        ),
      ),
    );
  }
}

/// A section heading inside a pill panel: a quiet uppercase label, with an
/// optional figure on the right (that section's total).
class PillPanelLabel extends StatelessWidget {
  const PillPanelLabel({super.key, required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final style = TextStyle(
      fontSize: 10.5,
      fontWeight: AppFont.medium,
      letterSpacing: 0.5,
      color: AppPalette.textFaint,
    );
    return Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: style)),
        if (trailing != null)
          Text(
            trailing!,
            style: style.copyWith(
              color: AppPalette.textSecondary,
              letterSpacing: 0,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
      ],
    );
  }
}
