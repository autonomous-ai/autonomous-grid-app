import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the conversation keeps for itself before the preview panel may dock
/// beside it.
///
/// This is the composer's floor, and it moved: the row used to be a line of
/// inflexible controls that overflowed below ~550, so the pane refused to go
/// under 600. Grouping that row into two [Flexible] halves lets its pills
/// ellipsis instead, and the floor came down with it.
///
/// **Measured, not reasoned** — twice, because the first measurement was wrong
/// in two ways and shipped stripes across a real composer:
///
///  - it rendered `ComposerSection` bare, while the chat view wraps it in
///    `Padding(20, 10, 20, 20)`. The floor governs the *column*, so the harness
///    was 40px optimistic.
///  - it stood in for the three pickers with a pill that squeezed further than
///    the real [ComposerTrigger] does. That pill's floor is not zero: leading +
///    5 + the ellipsis + 1 + caret + 20 of button padding ≈ 58, whatever the
///    label says.
///
/// Re-measured with the real trigger and the real inset, and a leading glyph
/// 4px wider than any the app actually passes: clean at 396, overflowing at
/// 392. This is that with room to spare. Re-measure before moving it — the
/// failure mode is stripes, not a layout that merely looks tight.
const double kChatMinWidth = 440;

/// The preview panel takes a share of what's left rather than a fixed width: it
/// is a work surface, so on a wide window it should be worth working in, and on
/// a narrow one it shouldn't be the reason the chat is cramped.
const double kPreviewMinWidth = 420;

/// The widest share the app will hand the panel *by itself*, so a large monitor
/// doesn't open it onto half the world.
///
/// Not a limit on dragging. Once the user has taken hold of the seam they have
/// said what they want, and the only thing left to protect is the composer's
/// floor — which is why the chat can be pulled down to [kChatMinWidth] on a
/// wide window even though 45% of it would never have gone that far.
const double kPreviewMaxWidth = 760;

/// The same deal vertically, against a transcript that still has to be worth
/// reading above it.
const double kChatMinHeight = 260;
const double kBottomMinHeight = 180;

/// The tallest share the app picks on its own — a ceiling on the default, not
/// on the drag. See [kPreviewMaxWidth].
const double kBottomMaxHeight = 420;

/// The width the user dragged the preview panel to, or null to follow the share
/// the app picks.
///
/// Null is the resting state, not a number: a stored default would stop
/// answering to the window's width, so a panel sized on a large monitor would
/// arrive fixed and wrong on a laptop. Once dragged it sticks for the session —
/// long enough to be a decision, not so long that a bad drag outlives it.
final previewWidthOverrideProvider =
    NotifierProvider<PreviewWidthOverride, double?>(PreviewWidthOverride.new);

class PreviewWidthOverride extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double width) => state = width;

  void reset() => state = null;
}

/// The height the user dragged the bottom panel to, or null to follow the
/// share — see [previewWidthOverrideProvider] for why null is the default.
final bottomHeightOverrideProvider =
    NotifierProvider<BottomHeightOverride, double?>(BottomHeightOverride.new);

class BottomHeightOverride extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double height) => state = height;

  void reset() => state = null;
}

/// Every size the chat pane needs, resolved together.
@immutable
class PanelSizes {
  const PanelSizes({
    required this.previewWidth,
    required this.previewFits,
    required this.bottomHeight,
  });

  /// How wide the preview panel is drawn, docked or floating.
  final double previewWidth;

  /// Whether the window can host it *beside* the chat at all. False sends it to
  /// the floating fallback; the docked slot and the floating one are never both
  /// in the tree.
  final bool previewFits;

  final double bottomHeight;
}

/// Work out what fits, from the pane's own measurements and whatever the user
/// has dragged.
///
/// Pure, and out of `build` on purpose: this is four clamps that have to agree
/// with each other, and it was already the fiddliest thing in the pane before
/// dragging gave two of them a second source.
///
/// The clamps are what make dragging safe — a drag is only a *request*, and a
/// request that would overflow the composer or leave no transcript is met with
/// the nearest size that doesn't.
PanelSizes resolvePanelSizes({
  required double paneWidth,
  required double paneHeight,
  required double railWidth,
  required double? previewOverride,
  required double? bottomOverride,
}) {
  final free = paneWidth - railWidth;
  // What's left for the panel once the conversation has its floor. Negative on
  // a narrow window, which is the same answer as "it doesn't fit".
  final widthRoom = free - kChatMinWidth;
  final previewFits = widthRoom >= kPreviewMinWidth;
  // The app's own share is capped; a dragged width is not. Only the chat's
  // floor bounds it from here.
  final wantedWidth =
      previewOverride ??
      _clamp(free * 0.45, kPreviewMinWidth, kPreviewMaxWidth);
  final previewWidth = previewFits
      // Docked: never past what the chat can spare.
      ? _clamp(wantedWidth, kPreviewMinWidth, widthRoom)
      // Floating: the chat keeps its full width underneath, so the only limit
      // is the pane it floats in.
      : _clamp(wantedWidth, kPreviewMinWidth, free);

  final heightRoom = _max(paneHeight - kChatMinHeight, 0);
  final wantedHeight =
      bottomOverride ??
      _clamp(paneHeight * 0.34, kBottomMinHeight, kBottomMaxHeight);
  final bottomHeight = _clamp(wantedHeight, kBottomMinHeight, heightRoom);

  return PanelSizes(
    previewWidth: previewWidth,
    previewFits: previewFits,
    bottomHeight: bottomHeight,
  );
}

/// What one tab takes when the strip has room for every tab at full width.
const double kTabMaxWidth = 180;

/// The width a tab shrinks to before the strip gives up and scrolls instead.
///
/// Below this the label runs out before "Terminal 2" and "Terminal 3" differ,
/// which is the only job the label has.
const double kTabMinWidth = 96;

/// The gap after each tab. The last one's is the space before the "+".
const double kTabGap = 4;

/// How wide each tab is in a strip [available] px across holding [count] of
/// them — the same for all of them, so the row can't come out ragged.
///
/// Shrinks with the count rather than scrolling straight away: in a panel this
/// narrow the fourth tab used to push the "+" out of sight, and a control you
/// have to scroll to reach is one people conclude is missing. Past
/// [kTabMinWidth] the row scrolls instead, which is what [tabStripScrolls]
/// answers.
double tabStripTabWidth({required double available, required int count}) {
  if (count <= 0) return kTabMaxWidth;
  return _clamp(
    (available - kTabGap * count) / count,
    kTabMinWidth,
    kTabMaxWidth,
  );
}

/// Whether the tabs, already as narrow as they may go, still overrun the strip.
bool tabStripScrolls({required double available, required int count}) {
  if (count <= 0) return false;
  final width = tabStripTabWidth(available: available, count: count);
  return (width + kTabGap) * count > available;
}

/// `clamp` asserts low <= high, so a pane laid out shorter than a floor would
/// throw rather than degrade. When there is less room than the minimum, the
/// room wins: better a panel squeezed under its own floor than a crash.
double _clamp(double value, double low, double high) {
  if (high <= low) return high < 0 ? 0 : high;
  return value < low ? low : (value > high ? high : value);
}

double _max(double a, double b) => a > b ? a : b;
