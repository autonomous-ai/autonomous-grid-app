import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// A control in the Review toolbar: 26px tall, and quiet unless it is the row's
/// action.
///
/// Its own construction rather than a `FilledButton`, because a filled accent
/// pill in a 36px toolbar is the loudest thing on the panel and this row sits
/// under the chat, not over it. [tinted] is as far as it goes: an accent
/// *wash*, which is what the app puts under a primary action that hasn't
/// hardened into a button.
///
/// Shared with the scope menu's button so the two ends of the toolbar are the
/// same object in two colours — they were drawn twice before, and drifted.
class ToolbarPill extends StatefulWidget {
  const ToolbarPill({
    super.key,
    required this.child,
    required this.onTap,
    this.tinted = false,
    this.active = false,
  });

  /// What the pill says. Its colours are the caller's — [tint] is the one to
  /// use, so the ink and the fill agree.
  final Widget child;

  /// Null while the action is in flight; the pill stops responding and keeps
  /// its shape rather than disappearing out from under the pointer.
  final VoidCallback? onTap;

  /// Washed with accent: this pill is the row's action, not one of its
  /// switches.
  final bool tinted;

  /// Drawn as though hovered — for a pill with its panel open under it.
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

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Opaque, not the default: the padding around the label has to answer
        // the pointer too, or the pill has dead corners.
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: _fill(lit),
            borderRadius: BorderRadius.circular(AppControl.radius),
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }

  Color _fill(bool lit) {
    if (!widget.tinted) return lit ? AppSurface.hoverFill : Colors.transparent;
    return lit ? AppSurface.accentWashHover : AppSurface.accentWash;
  }
}
