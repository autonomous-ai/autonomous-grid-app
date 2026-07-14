import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One row in the sidebar: an icon, a label, and an optional trailing widget.
///
/// The sidebar's single row recipe — nav entries, the New chat action and the
/// saved conversations all use it, so they line up and highlight identically
/// instead of each inventing its own padding and hover.
class SidebarItem extends StatefulWidget {
  const SidebarItem({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.emphasized = false,
    this.trailing,
    this.tooltip,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool selected;
  final bool enabled;

  /// Draws the label in the primary ink even when unselected — for the row that
  /// is the sidebar's main action ("New chat").
  final bool emphasized;

  /// Revealed on hover (e.g. a conversation's delete button).
  final Widget? trailing;
  final String? tooltip;

  @override
  State<SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<SidebarItem> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(8));
    final strong = widget.selected || widget.emphasized;
    final ink = strong ? AppPalette.textPrimary : AppPalette.textSecondary;
    final fill = widget.selected
        ? AppSurface.selectedFill
        : (_hovered ? AppSurface.hoverFill : Colors.transparent);

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Press feedback: the row dips slightly under the pointer and springs
      // back on release. A transform, so it never nudges neighbouring rows.
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            // Flat, like Codex — the selected row is a soft rounded fill, no lift.
            color: fill,
            borderRadius: radius,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.enabled ? widget.onTap : null,
              onTapDown: (_) => _setPressed(true),
              onTapUp: (_) => _setPressed(false),
              onTapCancel: () => _setPressed(false),
              child: SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 5, 0),
                  child: Row(
                    children: [
                      if (widget.icon != null) ...[
                        // A whisper of drift on hover, so the icon feels alive
                        // as the pointer lands — nudged right, never resized.
                        AnimatedSlide(
                          offset: Offset(_hovered ? 0.12 : 0, 0),
                          duration: const Duration(milliseconds: 130),
                          curve: Curves.easeOut,
                          child: Icon(widget.icon, size: 16, color: ink),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          strutStyle: const StrutStyle(
                            fontSize: 13.5,
                            height: 1.25,
                            forceStrutHeight: true,
                          ),
                          style: TextStyle(
                            color: ink,
                            fontSize: 13.7,
                            height: 1.25,
                            fontWeight: strong
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      // Keep the action mounted so hovering never changes text
                      // metrics or row height.
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: AnimatedOpacity(
                            opacity: _hovered ? 1 : 0,
                            duration: const Duration(milliseconds: 100),
                            curve: Curves.easeOut,
                            child: widget.trailing,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }
}

/// A quiet section label above a group of [SidebarItem]s ("Chats", "Workspace").
class SidebarSectionLabel extends StatelessWidget {
  const SidebarSectionLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 17, 10, 7),
      child: Text(
        label,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
