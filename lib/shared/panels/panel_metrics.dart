import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'panel_tabs.dart';

/// The panel beside the work takes a share of what's left rather than a fixed
/// width: it is a work surface, so on a wide window it should be worth working
/// in, and on a narrow one it shouldn't be the reason the conversation is
/// cramped.
const double kSidePanelMinWidth = 420;

/// The widest share the app will hand a side panel *by itself*, so a large
/// monitor doesn't open it onto half the world.
///
/// Not a limit on dragging. Once the user has taken hold of the seam they have
/// said what they want, and the only thing left to protect is the floor of
/// whatever is beside it.
const double kSidePanelMaxWidth = 760;

/// The width the user dragged a side panel to, or null to follow the share the
/// app picks.
///
/// Null is the resting state, not a number: a stored default would stop
/// answering to the window's width, so a panel sized on a large monitor would
/// arrive fixed and wrong on a laptop. Once dragged it sticks for the session —
/// long enough to be a decision, not so long that a bad drag outlives it.
final panelWidthOverrideProvider =
    NotifierProvider.family<PanelWidthOverride, double?, PanelHost>(
      PanelWidthOverride.new,
    );

class PanelWidthOverride extends Notifier<double?> {
  PanelWidthOverride(this.host);

  /// The panel this width belongs to — the family argument.
  final PanelHost host;

  @override
  double? build() => null;

  void set(double width) => state = width;

  /// Back to the share the app would have picked — what a double-click on the
  /// seam does, and the way out of a drag that went somewhere useless.
  void reset() => state = null;
}

/// Whether a panel has the whole pane, with the conversation slid out from
/// under it.
///
/// A second state of the same panel rather than a second panel: what you are
/// doing in there — reading a long diff, watching a build scroll past — is
/// sometimes the whole job for a minute, and 45% of the window is not enough of
/// it. The conversation is hidden rather than closed, so the draft, the scroll
/// and the turn in flight are all still there when it comes back.
final panelExpandedProvider =
    NotifierProvider.family<PanelExpanded, bool, PanelHost>(PanelExpanded.new);

class PanelExpanded extends Notifier<bool> {
  PanelExpanded(this.host);

  /// The panel this belongs to — the family argument.
  final PanelHost host;

  @override
  bool build() {
    // Expanded is a state an *open* panel can be in, so opening or closing the
    // panel puts it back to its normal width. Without this, closing while
    // expanded would leave the flag set and the next open would swallow the
    // conversation with no warning.
    ref.watch(panelOpenProvider(host));
    return false;
  }

  void toggle() => state = !state;
}

/// How wide a side panel is drawn, and whether it fits beside the work at all.
@immutable
class SidePanelSize {
  const SidePanelSize({required this.width, required this.fits});

  final double width;

  /// Whether the pane can host the panel *beside* the work. False sends it to
  /// a floating fallback where a screen offers one.
  final bool fits;
}

/// Work out what a side panel gets of [paneWidth], from what the work beside it
/// must keep and whatever the user has dragged.
///
/// Pure, and out of `build` on purpose: these are clamps that have to agree
/// with each other, and dragging gives them a second source.
///
/// The clamps are what make dragging safe — a drag is only a *request*, and a
/// request that would overflow the composer beside it is met with the nearest
/// size that doesn't.
SidePanelSize resolveSidePanel({
  required double paneWidth,
  required double mainMinWidth,
  required double? override,
}) {
  // What's left for the panel once the work beside it has its floor. Negative
  // on a narrow window, which is the same answer as "it doesn't fit".
  final room = paneWidth - mainMinWidth;
  final fits = room >= kSidePanelMinWidth;
  // The app's own share is capped; a dragged width is not. Only the floor
  // beside it bounds that.
  final wanted =
      override ??
      _clamp(paneWidth * 0.45, kSidePanelMinWidth, kSidePanelMaxWidth);
  return SidePanelSize(
    width: fits
        // Docked: never past what the work beside it can spare.
        ? _clamp(wanted, kSidePanelMinWidth, room)
        // Floating: the work keeps its full width underneath, so the only limit
        // is the pane it floats in.
        : _clamp(wanted, kSidePanelMinWidth, paneWidth),
    fits: fits,
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

/// `clamp` asserts low <= high, so a pane laid out narrower than a floor would
/// throw rather than degrade. When there is less room than the minimum, the
/// room wins: better a panel squeezed under its own floor than a crash.
double _clamp(double value, double low, double high) {
  if (high <= low) return high < 0 ? 0 : high;
  return value < low ? low : (value > high ? high : value);
}
