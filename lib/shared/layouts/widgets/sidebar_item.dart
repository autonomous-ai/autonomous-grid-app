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

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(10));
    final strong = widget.selected || widget.emphasized;
    final ink = strong ? AppPalette.textPrimary : AppPalette.textSecondary;
    final fill = widget.selected
        ? AppSurface.selectedFill
        : (_hovered ? AppSurface.hoverFill : Colors.transparent);
    final border = widget.selected
        ? const BorderSide(color: Color(0x08000000))
        : BorderSide.none;

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.fromBorderSide(border),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.enabled ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 16, color: ink),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ink,
                        fontSize: 13,
                        fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  // The slot keeps its size whether or not the trailing action is
                  // showing, so hovering a row never resizes it.
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: _hovered ? widget.trailing : null,
                  ),
                ],
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
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
