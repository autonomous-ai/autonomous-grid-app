import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'sidebar_item.dart';

/// How many rows a sidebar section shows before the rest sit behind "Show more",
/// and how many more each click reveals.
///
/// One number for every section in the rail — the project list, a project's
/// chats, and the loose chats — so the rail never grows a second,
/// differently-sized page.
const int kSidebarPageSize = 5;

/// How many rows a section shows once it has been paged open [pages] times.
///
/// A function rather than `shown += kSidebarPageSize` at each call site, so the
/// three sections can't drift apart and so the count is always clamped to what's
/// actually there: a section expanded past a list that later shrank (a chat
/// archived, a project removed) must not keep claiming there's more to see.
int sidebarPageCount(int pages, int total) {
  final shown = kSidebarPageSize * pages;
  return shown < total ? shown : total;
}

/// The row that closes a truncated sidebar section: quiet text that reveals the
/// next [kSidebarPageSize] rows, and stops being built once the list is fully
/// shown.
///
/// Deliberately lighter than a [SidebarItem] — shorter, smaller, faint until you
/// reach for it. It's chrome *about* the list, not an entry *in* it, so it must
/// not read as one more chat you could open.
class SidebarShowMore extends StatefulWidget {
  const SidebarShowMore({
    super.key,
    required this.remaining,
    required this.onTap,
    this.indented = false,
  });

  /// How many rows are still hidden — carried in the tooltip, so the row itself
  /// stays the same two words at every list length.
  final int remaining;

  final VoidCallback onTap;

  /// Line the label up with the chats it follows: a project's chats, and the
  /// loose ones, are indented one step. The row under the project *list* stays
  /// out at the rail's edge, which is what tells you it belongs to the section
  /// rather than to the chats of the last project above it.
  final bool indented;

  @override
  State<SidebarShowMore> createState() => _SidebarShowMoreState();
}

class _SidebarShowMoreState extends State<SidebarShowMore> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppSurface from inside the rail's lazy list — watch here
    // or this row keeps the palette it was first painted with.
    AppTheme.watch(context);
    final hot = _hovered;
    // Rests at the hint ink so a truncated section stays quiet, and climbs to
    // the primary ink under the pointer: an affordance that stays dim while
    // you're aiming at it reads as a caption, not a control.
    final ink = hot ? AppPalette.textPrimary : AppPalette.textFaint;

    return Padding(
      // The same 28px step a chat row takes, plus the 1px of vertical breathing
      // room every rail row keeps, so neighbouring highlights never touch.
      padding: EdgeInsets.only(
        left: widget.indented ? 28 : 0,
        top: 1,
        bottom: 1,
      ),
      child: Semantics(
        button: true,
        label: 'Show more',
        child: Tooltip(
          message: '${widget.remaining} more',
          waitDuration: const Duration(milliseconds: 600),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _setHovered(true),
            onExit: (_) => _setHovered(false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOut,
                height: 30,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: SidebarItem.iconGutter,
                ),
                decoration: BoxDecoration(
                  color: hot ? AppSurface.hoverFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Show more',
                  style: TextStyle(
                    color: ink,
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
