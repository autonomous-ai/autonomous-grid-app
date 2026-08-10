/// How the node dashboard arranges its cards — pure arithmetic, so the widget
/// stays declarative and the edge cases below are unit tested rather than found
/// by resizing a window.
library;

/// Width a card aims for before another column is added. Sized so a card keeps
/// its two detail columns readable rather than stretching one row of labels
/// across a wide display.
const double kNodeCardTargetWidth = 340;

/// Gap between cards, on both axes.
const double kNodeCardGap = 14;

/// How many cards fit across [width].
///
/// [kNodeCardTargetWidth] is a target, not a maximum: the caller stretches cards
/// to fill what is left over, so a row stays flush with the dialog's edges
/// instead of trailing a ragged gap.
///
/// Never returns less than 1. A narrow window — or a zero width during the first
/// layout pass, before constraints are known — must yield a single column, not a
/// zero the caller would divide by.
int dashboardColumns(double width, {double gap = kNodeCardGap}) {
  if (width <= 0) return 1;
  final fit = ((width + gap) / (kNodeCardTargetWidth + gap)).floor();
  return fit < 1 ? 1 : fit;
}
