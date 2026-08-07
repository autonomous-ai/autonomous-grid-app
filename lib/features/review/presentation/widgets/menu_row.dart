import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';

/// The gutter that turns a row's hover fill into an inset pill rather than a
/// band running the full width of the panel — the same 6 the chat menu uses.
const double kMenuRowGutter = 6;

/// Row height and rounding, matching the app's other menu rows.
const double kMenuRowHeight = 32;

/// The inset from a row's own edge to its contents — where the check on a
/// chosen row lands, and so where anything drawn *beside* a row (a submenu's
/// chevron, which Material insists on placing itself) has to land to line up
/// with it.
const double kMenuRowPadding = 9;

/// The trailing glyph's box. Every row that has one uses the same size, so the
/// column they form is straight.
const double kMenuRowGlyph = 14;
final BorderRadius kMenuRowRadius = BorderRadius.circular(AppControl.radius);

/// One row of the Review scope menu.
///
/// Its own widget rather than a `MenuItemButton`: Material's row brings a ripple
/// the app disables everywhere, a 48px tap target, and no way to put a wash
/// behind the chosen row without it reading as a button dropped into the menu.
/// This is the same construction the chat menu uses, so the two look like one
/// design system.
class MenuRow extends StatefulWidget {
  const MenuRow({
    super.key,
    required this.label,
    required this.width,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.detail,
    this.trailing,
    this.enabled = true,
  });

  final String label;

  /// The second line under it — a commit's author and age, a branch's remote.
  final String? detail;

  /// What sits at the end of the row: a count, the keys that do the same
  /// thing. Drawn before the chosen-row check, so a row can carry both.
  final Widget? trailing;

  final IconData? icon;
  final double width;
  final bool selected;

  /// A row that can't be picked yet, with the reason belonging in [detail] —
  /// greyed rather than hidden, so the menu keeps its shape.
  final bool enabled;

  final VoidCallback onTap;

  @override
  State<MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Menu content lives in an overlay, detached from the anchor's rebuilds —
    // so it watches the palette itself.
    AppTheme.watch(context);
    final selected = widget.selected;
    final enabled = widget.enabled;
    final tint = !enabled
        ? AppPalette.textFaint
        : selected
        ? AppPalette.accentOnSurface
        : _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kMenuRowGutter),
      child: Material(
        // The chosen row's wash goes on the Material itself, not on a box
        // inside the InkWell: an `Ink` decoration paints *over* the hover
        // highlight, so the selected row would be the one row that stopped
        // responding to the pointer.
        color: selected ? AppSurface.accentWash : Colors.transparent,
        borderRadius: kMenuRowRadius,
        child: InkWell(
          onTap: enabled ? widget.onTap : null,
          borderRadius: kMenuRowRadius,
          hoverColor: AppSurface.hoverFill,
          // The app's menus have no ink ripple; InkWell brings one by default.
          splashFactory: NoSplash.splashFactory,
          onHover: (value) => setState(() => _hovered = value),
          child: MenuRowBody(
            label: widget.label,
            detail: widget.detail,
            trailing: widget.trailing,
            icon: widget.icon,
            width: widget.width - kMenuRowGutter * 2,
            selected: selected,
            enabled: enabled,
            tint: tint,
          ),
        ),
      ),
    );
  }
}

/// What a menu row looks like, without deciding how it is pressed.
///
/// Shared because a submenu row is opened by [SubmenuButton], which brings its
/// own gesture handling — wrapping [MenuRow] inside one would put two
/// interactive layers on the same row, and the two would disagree about hover.
class MenuRowBody extends StatelessWidget {
  const MenuRowBody({
    super.key,
    required this.label,
    required this.width,
    this.detail,
    this.icon,
    this.trailing,
    this.selected = false,
    this.enabled = true,
    this.tint,
  });

  final String label;
  final String? detail;

  /// What sits at the end of the row — see [MenuRow.trailing].
  final Widget? trailing;

  final IconData? icon;
  final double width;
  final bool selected;
  final bool enabled;

  /// The glyph's colour, when the row that owns it tracks its own hover.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final ink =
        tint ?? (enabled ? AppPalette.textSecondary : AppPalette.textFaint);
    return SizedBox(
      width: width,
      height: detail == null ? kMenuRowHeight : 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMenuRowPadding),
        child: Row(
          children: [
            // Fixed leading slot so every label starts at the same x, whatever
            // the glyph's own width — and so the rows without a glyph still
            // line up with the ones that have one.
            SizedBox(
              width: 16,
              child: icon == null ? null : Icon(icon, size: 14, color: ink),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _Label(row: this, enabled: enabled),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              // Faded rather than hidden on a row that can't be picked: the
              // count is *why* the row is greyed, so taking it away removes
              // the explanation.
              Opacity(opacity: enabled ? 1 : 0.5, child: trailing),
            ],
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(
                LucideIcons.check,
                size: kMenuRowGlyph,
                color: AppPalette.accentOnSurface,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The chevron that says a row opens more rows.
///
/// Its own widget because it isn't drawn *inside* the row: [SubmenuButton]
/// keeps a slot at the end of its label for exactly this glyph and won't give
/// it up, so the row is made narrower and this is handed over to fill it —
/// which is what lands it in the same column as the chosen row's check.
class MenuRowChevron extends StatelessWidget {
  const MenuRowChevron({super.key});

  /// What the glyph and its inset come to — subtract this from a row's width
  /// and its contents keep the position they have everywhere else.
  static const double width = kMenuRowGlyph + kMenuRowPadding;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(right: kMenuRowPadding),
      child: Icon(
        LucideIcons.chevronRight,
        size: kMenuRowGlyph,
        color: AppPalette.textFaint,
      ),
    );
  }
}

/// The row's own words: its label, and the quiet line under it when it has one.
class _Label extends StatelessWidget {
  const _Label({required this.row, required this.enabled});

  final MenuRowBody row;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final detail = row.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: row.selected ? AppFont.semibold : AppFont.regular,
            color: enabled ? AppPalette.textPrimary : AppPalette.textFaint,
          ),
        ),
        if (detail != null)
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
          ),
      ],
    );
  }
}

/// A heading over a run of rows.
class MenuHeading extends StatelessWidget {
  const MenuHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kMenuRowGutter + 9, 7, 12, 6),
      child: Text(
        text,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          fontWeight: AppFont.medium,
        ),
      ),
    );
  }
}

/// The hairline between two runs of rows.
class MenuDivider extends StatelessWidget {
  const MenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kMenuRowGutter + 9,
        vertical: 5,
      ),
      child: Divider(height: 1, color: AppPalette.divider),
    );
  }
}
