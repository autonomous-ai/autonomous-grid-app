import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';

/// The two menus the Skills screen opens — "Add skill" and a row's "Share" —
/// built to the same recipe as the project and chat menus (§5 of the design
/// system): a 6px gutter so hover reads as an inset pill, radius 8, no ripple,
/// and a 16px leading slot that keeps the labels aligned.
///
/// Shared between the two rather than hand-rolled twice: they open on the same
/// screen, a row apart, and two menus that disagree about their own row height
/// read as a bug.
const double kSkillMenuWidth = 216;

/// One row, and the panel's own vertical padding — [appMenuStyle]'s `vertical:
/// 5`. Menus are positioned by summing these, so a row that measures taller
/// than this floats the whole panel off its button.
const double kSkillMenuRowHeight = 34;
const double kSkillMenuPadding = 5;

Size skillMenuSize(int rows) =>
    Size(kSkillMenuWidth, kSkillMenuPadding * 2 + kSkillMenuRowHeight * rows);

MenuStyle skillMenuStyle() => appMenuStyle().copyWith(
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(vertical: kSkillMenuPadding),
  ),
  minimumSize: const WidgetStatePropertyAll(Size(kSkillMenuWidth, 0)),
);

/// One row of a skills menu.
///
/// Stateful for its own hover: the glyph has to climb to
/// [AppPalette.textPrimary] under the pointer. An icon that stays dim while the
/// cursor sits on it reads as decoration, and nothing above this row tracks
/// hover per-row to do it here.
class SkillMenuItem extends StatefulWidget {
  const SkillMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.detail,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// A quieter word after the label — what the row will actually do, when the
  /// label alone can't say it ("Upload a skill · from a folder").
  final String? detail;

  @override
  State<SkillMenuItem> createState() => _SkillMenuItemState();
}

class _SkillMenuItemState extends State<SkillMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // The menu lives in an overlay this build can't be reached through, so it
    // subscribes to the brightness itself.
    AppTheme.watch(context);
    final ink = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          height: kSkillMenuRowHeight,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Icon(widget.icon, size: 15, color: ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFont.medium,
                    color: ink,
                  ),
                ),
              ),
              if (widget.detail != null) ...[
                const SizedBox(width: 8),
                Text(
                  widget.detail!,
                  style: TextStyle(fontSize: 11, color: AppPalette.textFaint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
