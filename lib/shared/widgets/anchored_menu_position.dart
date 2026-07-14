import 'package:flutter/material.dart';

/// Calculates a stable menu position relative to an anchor.
///
/// `MenuAnchor` clamps oversized menus against the window edge after resolving
/// the anchor. When the anchor is a small pill near an edge, tiny offsets are
/// ignored by that clamp. This helper chooses an in-bounds overlay position
/// first, then returns the local offset `MenuController.open(position:)` needs.
Offset anchoredMenuPosition(
  BuildContext context, {
  required Size menuSize,
  double margin = 12,
  double gap = 8,
  bool alignEnd = false,
  bool preferAbove = false,
}) {
  final anchorObject = context.findRenderObject();
  final overlayObject = Overlay.of(context).context.findRenderObject();
  if (anchorObject is! RenderBox || overlayObject is! RenderBox) {
    return Offset.zero;
  }

  final anchorTopLeft = anchorObject.localToGlobal(
    Offset.zero,
    ancestor: overlayObject,
  );
  final anchorSize = anchorObject.size;
  final overlaySize = overlayObject.size;

  final preferredLeft = alignEnd
      ? anchorTopLeft.dx + anchorSize.width - menuSize.width
      : anchorTopLeft.dx;
  final left = _clamp(
    preferredLeft,
    margin,
    overlaySize.width - menuSize.width - margin,
  );

  final below = anchorTopLeft.dy + anchorSize.height + gap;
  final above = anchorTopLeft.dy - menuSize.height - gap;
  final preferredTop = preferAbove ? above : below;
  final fallbackTop = preferAbove ? below : above;
  final top = _fitsVertically(preferredTop, menuSize, overlaySize, margin)
      ? preferredTop
      : _clamp(
          fallbackTop,
          margin,
          overlaySize.height - menuSize.height - margin,
        );

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
