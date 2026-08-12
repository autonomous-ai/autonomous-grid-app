import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A quiet 24px square icon target that warms and fills under the pointer — the
/// top bar header's hover treatment.
///
/// Shared rather than one per header: the bar carries the open chat's "…" and
/// the open project's, and the two have to be the same button rather than
/// lookalikes that drift apart.
class HeaderHoverButton extends StatefulWidget {
  const HeaderHoverButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  State<HeaderHoverButton> createState() => _HeaderHoverButtonState();
}

class _HeaderHoverButtonState extends State<HeaderHoverButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 17,
                color: _hovered
                    ? AppPalette.textPrimary
                    : AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
