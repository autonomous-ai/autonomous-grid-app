import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/panels/panel_metrics.dart';
import '../../../shared/panels/panel_tabs.dart';

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

/// The same deal vertically, against a transcript that still has to be worth
/// reading above it.
const double kChatMinHeight = 260;
const double kBottomMinHeight = 180;

/// The tallest share the app picks on its own — a ceiling on the default, not
/// on the drag. See [kSidePanelMaxWidth].
const double kBottomMaxHeight = 420;

/// The width the user dragged the preview panel to — the shared side-panel
/// width, named here so the chat's own files don't each have to say which panel
/// they mean.
final previewWidthOverrideProvider = panelWidthOverrideProvider(
  PanelHost.preview,
);

/// The height the user dragged the bottom panel to, or null to follow the
/// share — see [panelWidthOverrideProvider] for why null is the default.
///
/// Its own provider rather than a third member of that family: the family is
/// widths, and this panel is the one that grows the other way.
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
/// The width half is [resolveSidePanel] — the same arithmetic the Code pane
/// runs for the panel beside a project, so the two panels can't drift into
/// different ideas of how wide a work surface should be.
PanelSizes resolvePanelSizes({
  required double paneWidth,
  required double paneHeight,
  required double railWidth,
  required double? previewOverride,
  required double? bottomOverride,
}) {
  final preview = resolveSidePanel(
    paneWidth: paneWidth - railWidth,
    mainMinWidth: kChatMinWidth,
    override: previewOverride,
  );

  final heightRoom = _max(paneHeight - kChatMinHeight, 0);
  final wantedHeight =
      bottomOverride ??
      _clamp(paneHeight * 0.34, kBottomMinHeight, kBottomMaxHeight);
  final bottomHeight = _clamp(wantedHeight, kBottomMinHeight, heightRoom);

  return PanelSizes(
    previewWidth: preview.width,
    previewFits: preview.fits,
    bottomHeight: bottomHeight,
  );
}

/// `clamp` asserts low <= high, so a pane laid out shorter than a floor would
/// throw rather than degrade. When there is less room than the minimum, the
/// room wins: better a panel squeezed under its own floor than a crash.
double _clamp(double value, double low, double high) {
  if (high <= low) return high < 0 ? 0 : high;
  return value < low ? low : (value > high ? high : value);
}

double _max(double a, double b) => a > b ? a : b;
