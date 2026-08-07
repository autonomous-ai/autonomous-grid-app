import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The narrowest the column beside a panel's work is worth keeping. Below this
/// every file name is an ellipsis and the count beside it has nowhere to go.
const double kPanelSideMin = 180;

/// What the work itself keeps however far the seam is dragged — a diff in less
/// than this is a column of wrapped fragments rather than something to read.
const double kPanelMainMin = 240;

/// The widest share the app hands the column *by itself*.
///
/// Not a limit on dragging: once the user has taken hold of the seam they have
/// said what they want, and the only thing left to protect is [kPanelMainMin].
const double kPanelSideMax = 280;

/// The width the user dragged a panel's side column to, or null to follow the
/// share the app picks.
///
/// Null is the resting state rather than a number, for the reason
/// `previewWidthOverrideProvider` gives: a stored default would stop answering
/// to the panel's own width, so a column sized inside a wide panel would arrive
/// fixed and wrong in a narrow one.
///
/// One width for every tab, not one each: it is the same slot in the same
/// panel, and a seam that jumped as you switched between the changed files and
/// the file tree would read as the panel resizing itself.
final panelSideWidthProvider = NotifierProvider<PanelSideWidth, double?>(
  PanelSideWidth.new,
);

class PanelSideWidth extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double width) => state = width;

  /// Back to the share the app would have picked — what a double-click on the
  /// seam does, and the way out of a drag that went somewhere useless.
  void reset() => state = null;
}

/// How wide to draw the side column in a panel [panelWidth] across.
///
/// Pure and out of `build` so the clamps can be tested: a drag is only a
/// *request*, and one that would starve either side is met with the nearest
/// width that doesn't.
double resolvePanelSideWidth({
  required double panelWidth,
  required double? override,
}) {
  final wanted =
      override ?? _clamp(panelWidth * 0.3, kPanelSideMin, kPanelSideMax);
  return _clamp(wanted, kPanelSideMin, panelWidth - kPanelMainMin);
}

/// `clamp` asserts low <= high, so a panel laid out narrower than both floors
/// would throw rather than degrade. When there is less room than the minimum,
/// the room wins.
double _clamp(double value, double low, double high) {
  if (high <= low) return high < 0 ? 0 : high;
  return value < low ? low : (value > high ? high : value);
}
