import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart' show appMenuStyle;

/// One menu row's box, and the gap that makes its hover read as an inset pill.
const double kAccessMenuRowHeight = 34;
const double kAccessMenuRowGap = 1;

/// What a row costs the panel, vertically.
const double kAccessMenuRow = kAccessMenuRowHeight + kAccessMenuRowGap * 2;

/// The panel's own vertical padding — must match `appMenuStyle()`, which sets
/// `symmetric(vertical: 5)`. A menu that opens upward places itself by summing
/// what it thinks it draws, so a stale copy of this number floats the panel off
/// its button.
const double kAccessMenuPanelPadding = 5;

/// A divider row, padded like [AccessMenuDivider] draws it.
const double kAccessMenuDividerHeight = 9;

/// A row carrying a two-line explanation under its label — see
/// [AccessMenuRow.detail]. Fixed rather than measured, because an upward menu
/// places itself by summing what it expects to draw.
const double kAccessMenuDetailRow = 68;

/// The panel size to predict for [AccessMenuButton.menuSize].
Size accessMenuSize({
  required double width,
  required int rows,
  int detailRows = 0,
  bool divider = false,
  double extra = 0,
}) => Size(
  width,
  rows * kAccessMenuRow +
      detailRows * kAccessMenuDetailRow +
      (divider ? kAccessMenuDividerHeight : 0) +
      extra +
      kAccessMenuPanelPadding * 2,
);

/// The share sheet's menu trigger: a label and a caret, with no box around
/// them.
///
/// Google Drive's share sheet draws every one of its choosers this way — the
/// role beside a person, the blanket access rule — and the shape is doing real
/// work: a boxed field beside an email box reads as a second thing to fill in,
/// while this reads as the current answer, which happens to be changeable. It
/// is also what lets the *explanation* live in the row at dialog width instead
/// of inside a menu clipped to a field's width.
///
/// Not [AppSelectField]: that control is a form field, correct where the answer
/// is being entered (the create-grid form still uses it). This one reports.
class AccessMenuButton extends StatefulWidget {
  const AccessMenuButton({
    super.key,
    required this.label,
    required this.menuSize,
    required this.itemsBuilder,
    this.strong = false,
    this.enabled = true,
    this.alignEnd = false,
    this.tooltip,
  });

  /// The current answer — never a placeholder. This control always has one.
  final String label;

  /// What the panel is expected to measure, for [anchoredMenuPosition].
  final Size menuSize;

  /// The rows, built with the controller so a row can close the menu it is in.
  final List<Widget> Function(MenuController controller) itemsBuilder;

  /// Heavier label, for the access rule — the one answer in the sheet that is
  /// about the grid rather than about one person.
  final bool strong;

  /// False when there is nothing to choose: the label still shows, because
  /// what the grant IS stays worth reading when it can't be changed.
  final bool enabled;

  /// Hang the panel off the trigger's trailing edge — for a trigger sitting at
  /// the right edge of a row, where a leftward-anchored panel would run out of
  /// the dialog.
  final bool alignEnd;

  final String? tooltip;

  @override
  State<AccessMenuButton> createState() => _AccessMenuButtonState();
}

class _AccessMenuButtonState extends State<AccessMenuButton> {
  final _menu = MenuController();
  bool _hovered = false;

  void _toggle(BuildContext context) {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: widget.menuSize,
        margin: 8,
        alignEnd: widget.alignEnd,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (!widget.enabled) {
      return _StaticLabel(widget.label, strong: widget.strong);
    }

    // The caret rests a step below the label and comes up to meet it under the
    // pointer — the app's standard "fills in on hover", without which the row
    // reads as a printed value rather than a control.
    final caretInk = _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: WidgetStatePropertyAll(Size(widget.menuSize.width, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: widget.menuSize.width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.itemsBuilder(_menu),
          ),
        ),
      ],
      builder: (context, controller, _) {
        final button = Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppControl.radius),
          child: InkWell(
            onTap: () => _toggle(context),
            onHover: (value) => setState(() => _hovered = value),
            borderRadius: BorderRadius.circular(AppControl.radius),
            hoverColor: AppSurface.hoverFill,
            splashFactory: NoSplash.splashFactory,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 7, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: widget.strong
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(LucideIcons.chevronDown300, size: 13, color: caretInk),
                ],
              ),
            ),
          ),
        );
        final tooltip = widget.tooltip;
        return tooltip == null
            ? button
            : Tooltip(message: tooltip, child: button);
      },
    );
  }
}

/// The label alone, for a viewer with nothing to choose.
class _StaticLabel extends StatelessWidget {
  const _StaticLabel(this.text, {required this.strong});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      // Matches the button's text box, so a row doesn't shift by a few pixels
      // depending on who is looking at it.
      padding: const EdgeInsets.fromLTRB(10, 6, 7, 6),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: strong ? AppPalette.textPrimary : AppPalette.textSecondary,
          fontSize: 13,
          height: 1.2,
          fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// One row of an [AccessMenuButton] panel — hand-rolled per §5 of the design
/// system, because the app has no `menuButtonTheme` and a bare
/// `MenuItemButton` would take Material's square corners, 14pt label, grey
/// hover and ink ripple.
///
/// **Label and a tick by default.** The sentence explaining a choice normally
/// belongs in the row that opened this menu, at dialog width — that is how
/// Drive does it, and it is why Grid's own access menu used to print "…can use
/// this grid — includi…": a panel is only as wide as its button.
///
/// [detail] is the exception, for a choice whose name cannot carry itself. The
/// access rules are ordinary words ("Invite only"); the two member roles are
/// not, and reading them against each other is the whole decision — so those
/// rows take a short second line, capped at two.
class AccessMenuRow extends StatefulWidget {
  const AccessMenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.detail,
    this.selected = false,
    this.enabled = true,
    this.danger = false,
  });

  final String label;

  /// A short second line. Rows carrying one measure [kAccessMenuDetailRow];
  /// callers must count them into [accessMenuSize].
  final String? detail;

  /// Null-safe by construction: a row that cannot be chosen passes
  /// `enabled: false` and this is never called.
  final VoidCallback onTap;

  /// Marked three ways at once — wash, weight and tick — never by colour
  /// alone.
  final bool selected;

  /// A choice the control plane has no endpoint for. Drawn dimmed rather than
  /// dropped: the reader is comparing this grant with the one they hold, and a
  /// list with the other option missing invites the question "where is it?"
  /// with no answer on screen.
  final bool enabled;

  /// The destructive row, fenced below a divider — where Drive puts "Remove
  /// access" too.
  final bool danger;

  @override
  State<AccessMenuRow> createState() => _AccessMenuRowState();
}

class _AccessMenuRowState extends State<AccessMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Lives in the menu's overlay, detached from the dialog's subtree — so it
    // watches the palette itself.
    AppTheme.watch(context);
    final error = Theme.of(context).colorScheme.error;
    final radius = BorderRadius.circular(AppControl.radius);
    final ink = widget.danger
        ? error
        : !widget.enabled
        ? AppPalette.textFaint
        : _hovered || widget.selected
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: kAccessMenuRowGap,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: widget.enabled ? widget.onTap : null,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: radius,
          hoverColor: widget.danger
              ? error.withValues(alpha: 0.09)
              : AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: widget.selected
                  ? AppSurface.accentWash
                  : Colors.transparent,
              borderRadius: radius,
            ),
            child: SizedBox(
              height: widget.detail == null
                  ? kAccessMenuRowHeight
                  : kAccessMenuDetailRow - kAccessMenuRowGap * 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Row(
                  crossAxisAlignment: widget.detail == null
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    // Fixed slot, kept even when empty, so labels line up and
                    // nothing shifts sideways as the tick moves.
                    SizedBox(
                      width: 16,
                      // The tick sits on the label's line, not centred against
                      // a two-line row.
                      height: widget.detail == null ? null : 20,
                      child: widget.selected
                          ? Align(
                              alignment: Alignment.centerLeft,
                              child: Icon(
                                LucideIcons.check300,
                                size: 15,
                                color: AppPalette.accentMuted,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ink,
                              fontSize: 13,
                              height: 1.2,
                              fontWeight: widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          if (widget.detail case final line?) ...[
                            const SizedBox(height: 3),
                            Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppPalette.textSecondary,
                                fontSize: 12,
                                height: 1.32,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rule under a dimmed row, saying why it is dimmed.
///
/// A sentence inside a menu, which the rows themselves deliberately avoid — but
/// this one is not a choice, it is the reason a choice is missing, and the only
/// place it can be read is where the reader just tried to click.
class AccessMenuNote extends StatelessWidget {
  const AccessMenuNote(this.text, {super.key});

  final String text;

  /// What [accessMenuSize] should add for a two-line note.
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 2, 15, 8),
      child: Text(
        text,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          height: 1.35,
        ),
      ),
    );
  }
}

/// The hairline that fences a destructive row off from the rows above it.
class AccessMenuDivider extends StatelessWidget {
  const AccessMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: kAccessMenuDividerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, thickness: 1, color: AppPalette.divider),
      ),
    );
  }
}
