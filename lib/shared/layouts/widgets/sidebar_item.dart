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
    this.trailingWidth = 24,
    this.trailingAlwaysVisible = false,
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

  /// Width reserved for [trailing]. Defaults to one 24px action; a row with two
  /// (like a project's menu + new-chat) passes a wider value so neither clips.
  final double trailingWidth;

  /// Keep [trailing] visible without hovering — for a live status (a chat's
  /// "typing…" cue) that has to read at a glance, not a hover-only action.
  final bool trailingAlwaysVisible;
  final String? tooltip;

  /// The row's left inset — where its icon starts, measured from the row's own
  /// edge. Exposed so chrome placed alongside these rows (the Settings back
  /// link) can line its glyph up with them instead of hard-coding a copy.
  static const double iconGutter = 10;

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
    // The sidebar is mounted as `const AppSidebar()`, so a rebuild from the top
    // never reaches these rows — exactly the case AppTheme.watch exists for.
    // Without it the rail keeps the palette it was first painted with.
    AppTheme.watch(context);
    const radius = BorderRadius.all(Radius.circular(8));
    final strong = widget.selected || widget.emphasized;
    // A row's icon carries the accent whenever the row stands out — the selected
    // nav item and the emphasized action (New chat) both — so the accent reads
    // as "this is the one", matching the selected row's rail. Everything else
    // stays in ink.
    final ink = strong ? AppPalette.textPrimary : AppPalette.textSecondary;
    // The on-surface accent, not the fill one: this glyph sits on the row, so in
    // dark it needs the lighter value to stay legible — see [accentOnSurface].
    final iconInk = (widget.selected || widget.emphasized) && widget.enabled
        ? AppPalette.accentOnSurface
        : ink;
    // The emphasized row carries a whisper of accent wash so it reads as the
    // primary action without turning into a loud button; the selected row keeps
    // its neutral fill and instead earns the accent rail (below).
    final fill = widget.selected
        ? AppSurface.selectedFill
        : widget.emphasized
        ? (_hovered ? AppSurface.accentWashHover : AppSurface.accentWash)
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
        child: Stack(
          children: [
            AnimatedContainer(
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
                      padding: const EdgeInsets.fromLTRB(
                        SidebarItem.iconGutter,
                        0,
                        5,
                        0,
                      ),
                      child: Row(
                        children: [
                          if (widget.icon != null) ...[
                            // A whisper of drift on hover, so the icon feels alive
                            // as the pointer lands — nudged right, never resized.
                            AnimatedSlide(
                              offset: Offset(_hovered ? 0.12 : 0, 0),
                              duration: const Duration(milliseconds: 130),
                              curve: Curves.easeOut,
                              // Tween the colour so selecting a row eases its icon
                              // into the accent rather than snapping — in step
                              // with the rail that slides in alongside it.
                              child: TweenAnimationBuilder<Color?>(
                                tween: ColorTween(end: iconInk),
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeOut,
                                builder: (context, color, _) => Icon(
                                  widget.icon,
                                  size: 18,
                                  color: color ?? iconInk,
                                ),
                              ),
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
                                    ? AppFont.medium
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          // Keep the action mounted so hovering never changes text
                          // metrics or row height. A persistent trailing (a live
                          // status) shows without hover; a hover action stays
                          // hidden until the pointer lands.
                          SizedBox(
                            width: widget.trailingWidth,
                            height: 24,
                            child: IgnorePointer(
                              ignoring:
                                  !_hovered && !widget.trailingAlwaysVisible,
                              child: AnimatedOpacity(
                                opacity:
                                    _hovered || widget.trailingAlwaysVisible
                                    ? 1
                                    : 0,
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
            // The accent rail: a slim bar hugging the row's left edge while it's
            // the selected one. It slides in from the left and fades, so moving
            // the selection glides rather than blinks. Positioned outside the
            // fill so it never shifts the label — and pinned inside the 1px
            // vertical margin so it lines up with the rounded fill.
            Positioned(
              left: 0,
              top: 1,
              bottom: 1,
              child: Center(
                child: AnimatedSlide(
                  offset: Offset(widget.selected ? 0 : -0.6, 0),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: widget.selected ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    child: Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        // Same reason as the icon above — a mark on the row, so
                        // it takes the on-surface accent.
                        color: AppPalette.accentOnSurface,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
    // Same reason as the row above: const chrome reading a token.
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 17, 10, 7),
      child: Text(
        label,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.2,
          fontWeight: AppFont.medium,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
