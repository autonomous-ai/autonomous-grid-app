import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'sidebar_item.dart';

/// Where the trunk runs: dead centre of a project row's folder icon, so the
/// icons read as nodes threaded onto one line rather than as a list that
/// happens to have a rule beside it.
///
/// Derived from [SidebarItem.iconGutter] plus half an 18px glyph rather than
/// typed as `19`, so changing the rail's inset moves the guide with it instead
/// of leaving it pointing at nothing.
const double _trunkX = SidebarItem.iconGutter + 9;

/// How far the arm reaches out of the trunk towards a nested row.
///
/// A nested row's own box starts 28px in, so the arm stops 2px short of it:
/// touching the row's hover fill would make the guide read as part of the row
/// instead of as the thing holding it.
const double _armLength = 7;

/// How wide a berth the trunk gives a project's folder icon.
///
/// An 18px glyph centred in a 38px band leaves 10px clear at each end; 13
/// clears the glyph by 4px, which is what keeps the line from looking like it
/// is striking the icon out. What's left either side is ~6px of trunk — short,
/// but that is the point: enough to say the line passes behind the node.
const double _nodeGap = 13;

/// A hairline, like every other rule in the app. This is chrome about the list,
/// not an entry in it.
const double _stroke = 1;

/// What a row is to the guide line running down the rail's Projects block.
enum SidebarTimelineRole {
  /// A project. The trunk breaks around its folder icon and picks up again
  /// below, so the icon reads as a node sitting *on* the line.
  node,

  /// Something living inside a project — a chat, its "Show more", the "No chats
  /// yet" line. The trunk passes by and an arm reaches out to it.
  branch,
}

/// The guide line that ties the rail's projects and the chats inside them into
/// one tree.
///
/// The rail already says which chats belong to which project by indenting them,
/// but indentation alone goes quiet the moment a project's chats run long
/// enough that its folder row has scrolled away — the eye has nothing left to
/// follow back up. One continuous line through the whole block answers "what am
/// I still inside?" without the user having to scroll to find out.
///
/// Drawn per row rather than as one line behind the block, so no part of this
/// has to know how tall a row is: each row paints the segment crossing its own
/// band, and [above]/[below] are what stitch those segments into one line.
class SidebarTimeline extends StatelessWidget {
  const SidebarTimeline({
    super.key,
    required this.role,
    required this.child,
    this.above = true,
    this.below = true,
  });

  final SidebarTimelineRole role;
  final Widget child;

  /// Whether the trunk arrives from the row above. False on the first project —
  /// a line dangling up towards the "Projects" header would point at nothing.
  final bool above;

  /// Whether the trunk carries on into the row below. False on the last row of
  /// the block, where the tree ends and the line has to stop rather than run
  /// out into the "Chats" section, which isn't part of this tree.
  final bool below;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette.guide from inside the rail's lazy list, where an
    // ancestor's rebuild never lands — watch here or the guide keeps the
    // palette it was first painted with.
    AppTheme.watch(context);
    return CustomPaint(
      // In front of the child, not behind it: a project row's hover and
      // selection fills run the full width of the rail, and painting under them
      // would swallow the two short segments that carry the trunk past its icon
      // on exactly the row the pointer is on.
      foregroundPainter: _TimelinePainter(
        role: role,
        above: above,
        below: below,
        color: AppPalette.guide,
      ),
      child: child,
    );
  }
}

/// One row's share of the guide: the trunk crossing its band, broken around a
/// project's icon, plus the arm out to a nested row.
class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.role,
    required this.above,
    required this.below,
    required this.color,
  });

  final SidebarTimelineRole role;
  final bool above;
  final bool below;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = _stroke;
    final centerY = size.height / 2;
    // A project breaks the line around its icon; everything else lets it run
    // straight through, which is also what turns the last branch's two
    // segments into one clean elbow.
    final gap = role == SidebarTimelineRole.node ? _nodeGap : 0.0;

    if (above) {
      canvas.drawLine(Offset(_trunkX, 0), Offset(_trunkX, centerY - gap), line);
    }
    if (below) {
      canvas.drawLine(
        Offset(_trunkX, centerY + gap),
        Offset(_trunkX, size.height),
        line,
      );
    }
    if (role == SidebarTimelineRole.branch) {
      canvas.drawLine(
        Offset(_trunkX, centerY),
        Offset(_trunkX + _armLength, centerY),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      role != old.role ||
      above != old.above ||
      below != old.below ||
      color != old.color;
}
