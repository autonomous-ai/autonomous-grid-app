import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// A control in the Review toolbar: 26px tall, quiet at rest, and optionally
/// split so a caret can open a menu without swallowing the click that does the
/// thing.
///
/// Its own construction rather than a `FilledButton`, because a filled accent
/// pill in a 36px toolbar is the loudest thing on the panel and this row is
/// meant to sit under the tabs, not shout over them. [tinted] is as far as it
/// goes: an accent *wash*, which is what the app puts under a primary action
/// that hasn't hardened into a button (§ style guide, `accentWash`).
///
/// Shared with the scope menu's button so the two ends of the toolbar are the
/// same object in two colours — they were drawn twice before, and drifted.
class ToolbarPill extends StatefulWidget {
  const ToolbarPill({
    super.key,
    required this.child,
    required this.onTap,
    this.trailing,
    this.onTrailingTap,
    this.tinted = false,
    this.active = false,
  });

  /// What the pill says. Its colours are the caller's — [tint] is the one to
  /// use, so a tinted pill and a plain one agree with their fills.
  final Widget child;

  /// Null while the action is in flight; the pill stops responding and keeps
  /// its shape rather than disappearing out from under the pointer.
  final VoidCallback? onTap;

  /// A second, narrower zone at the end — the caret that opens the menu.
  final Widget? trailing;
  final VoidCallback? onTrailingTap;

  /// Washed with accent: this pill is the row's action, not one of its
  /// switches.
  final bool tinted;

  /// Drawn as though hovered — for a pill whose menu is open under it.
  final bool active;

  /// The ink a pill of this kind carries: accent when it is the action, the
  /// ordinary text colour otherwise, and faint when it can't be pressed.
  static Color tint({required bool tinted, required bool enabled}) => !enabled
      ? AppPalette.textFaint
      : tinted
      ? AppPalette.accentOnSurface
      : AppPalette.textPrimary;

  @override
  State<ToolbarPill> createState() => _ToolbarPillState();
}

class _ToolbarPillState extends State<ToolbarPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final enabled = widget.onTap != null;
    final lit = widget.active || (_hovered && enabled);
    final trailing = widget.trailing;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.hover,
        curve: AppMotion.curve,
        height: 26,
        decoration: BoxDecoration(
          color: _fill(lit),
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Zone(
              onTap: widget.onTap,
              padding: EdgeInsets.only(
                left: 9,
                right: trailing == null ? 9 : 7,
              ),
              child: widget.child,
            ),
            if (trailing != null) ...[
              // A hairline, not a gap: two rectangles with a slot between them
              // read as two controls, which is what this stopped being.
              SizedBox(
                width: 1,
                height: 14,
                child: ColoredBox(color: _seam(enabled)),
              ),
              _Zone(
                onTap: enabled ? widget.onTrailingTap : null,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: trailing,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _fill(bool lit) {
    if (!widget.tinted) return lit ? AppSurface.hoverFill : Colors.transparent;
    return lit ? AppSurface.accentWashHover : AppSurface.accentWash;
  }

  /// The line between the two halves: the accent's own ink at a quarter
  /// strength on a tinted pill, so it belongs to the fill rather than cutting
  /// across it.
  Color _seam(bool enabled) => widget.tinted
      ? AppPalette.accentOnSurface.withValues(alpha: enabled ? 0.28 : 0.15)
      : AppPalette.divider;
}

/// One half of the pill: its own hit area, with no chrome of its own.
class _Zone extends StatelessWidget {
  const _Zone({
    required this.onTap,
    required this.padding,
    required this.child,
  });

  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    // Transparent, not null: the padding around the label has to answer the
    // pointer too, or the pill has dead corners.
    behavior: HitTestBehavior.opaque,
    child: Padding(
      padding: padding,
      child: Center(child: child),
    ),
  );
}
