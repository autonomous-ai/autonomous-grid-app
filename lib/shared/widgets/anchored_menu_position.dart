import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Calculates a stable menu position relative to an anchor.
///
/// `MenuAnchor` clamps oversized menus against the window edge after resolving
/// the anchor. When the anchor is a small pill near an edge, tiny offsets are
/// ignored by that clamp. This helper chooses an in-bounds overlay position
/// first, then returns the local offset `MenuController.open(position:)` needs.
///
/// [menuSize] is what the caller expects the panel to measure; its height is
/// clamped to [maxHeight] — see [anchoredMenuOffset]. Pass [maxHeight] only if
/// the menu overrides `appMenuStyle`'s `maximumSize`.
Offset anchoredMenuPosition(
  BuildContext context, {
  required Size menuSize,
  double margin = 12,
  double gap = 8,
  bool alignEnd = false,
  bool preferAbove = false,
  double maxHeight = AppControl.menuMaxHeight,
}) {
  final anchorObject = context.findRenderObject();
  final overlayObject = Overlay.of(context).context.findRenderObject();
  if (anchorObject is! RenderBox || overlayObject is! RenderBox) {
    return Offset.zero;
  }

  return anchoredMenuOffset(
    anchorTopLeft: anchorObject.localToGlobal(
      Offset.zero,
      ancestor: overlayObject,
    ),
    anchorSize: anchorObject.size,
    overlaySize: overlayObject.size,
    menuSize: menuSize,
    margin: margin,
    gap: gap,
    alignEnd: alignEnd,
    preferAbove: preferAbove,
    maxHeight: maxHeight,
  );
}

/// The placement maths behind [anchoredMenuPosition], free of any render tree
/// so it can be reasoned about — and tested — on its own.
///
/// A menu always grows *down* from the offset it is opened at, so one that
/// opens upward is placed at "anchor top − its own height": the caller's
/// estimate of that height is load-bearing, and an estimate that overshoots
/// lifts the panel clear of its button by the difference. Since the panel can
/// never draw taller than [maxHeight] however long its list is, the estimate is
/// clamped here rather than at each of the seven call sites — the chat model
/// picker predicted 310 for a panel that drew 240 and hung 70px up in the
/// conversation.
Offset anchoredMenuOffset({
  required Offset anchorTopLeft,
  required Size anchorSize,
  required Size overlaySize,
  required Size menuSize,
  double margin = 12,
  double gap = 8,
  bool alignEnd = false,
  bool preferAbove = false,
  double maxHeight = AppControl.menuMaxHeight,
}) {
  final size = Size(
    menuSize.width,
    menuSize.height > maxHeight ? maxHeight : menuSize.height,
  );

  final preferredLeft = alignEnd
      ? anchorTopLeft.dx + anchorSize.width - size.width
      : anchorTopLeft.dx;
  final left = _clamp(
    preferredLeft,
    margin,
    overlaySize.width - size.width - margin,
  );

  final below = anchorTopLeft.dy + anchorSize.height + gap;
  final above = anchorTopLeft.dy - size.height - gap;
  final preferredTop = preferAbove ? above : below;
  final fallbackTop = preferAbove ? below : above;
  final top = _fitsVertically(preferredTop, size, overlaySize, margin)
      ? preferredTop
      : _clamp(fallbackTop, margin, overlaySize.height - size.height - margin);

  return Offset(left - anchorTopLeft.dx, top - anchorTopLeft.dy);
}

bool _fitsVertically(
  double top,
  Size menuSize,
  Size overlaySize,
  double margin,
) => top >= margin && top + menuSize.height <= overlaySize.height - margin;

double _clamp(double value, double min, double max) {
  if (max < min) return min;
  return value.clamp(min, max).toDouble();
}
