import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_theme.dart';
import '../shell_state.dart';
import 'app_sidebar.dart';
import 'app_sidebar_mini.dart';

/// The left rail, and the fold between its two widths.
///
/// It owns the rail's *surface* — the fill and the hairline against the pane —
/// while [AppSidebar] and [AppSidebarMini] own only what is drawn on it. That
/// split is what makes the fold a single moving edge instead of two: during the
/// crossfade both rails are on screen at partial opacity, and two translucent
/// fills stacked over the window would darken the whole rail for the length of
/// the animation, while two right-hand hairlines would put one at the boundary
/// and a second stranded 72px in.
///
/// The rails don't animate their own contents. The wide one stays laid out at
/// its full 284px and is clipped by the shrinking box, because its rows are
/// written for that width — reflowing a chat list through every width between
/// 284 and 72 would be 60 frames of text rewrapping, and it would look like it.
class SidebarFold extends ConsumerWidget {
  const SidebarFold({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No `begin` on the tween: a launch that opens collapsed should *be*
    // collapsed, not unfold itself while the user watches.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: ref.watch(sidebarCollapsedProvider) ? 0.0 : 1.0),
      duration: AppMotion.fold,
      // Fast off the mark and settling at the end, like every other motion in
      // the app — the pane arrives at its new width rather than drifting there.
      curve: AppMotion.curve,
      builder: (context, open, _) => _FoldedRail(open: open),
    );
  }
}

/// The rail at one point in the fold: `1` fully open, `0` folded to glyphs.
class _FoldedRail extends StatelessWidget {
  const _FoldedRail({required this.open});

  /// How far into being the wide rail, from 0 (glyphs) to 1 (open).
  final double open;

  /// How far each rail drifts sideways as it leaves.
  ///
  /// A hint, not a journey. Sliding the wide rail out by its whole 284px would
  /// drag every label across the screen and — on the way back — deliver the
  /// labels before their own icons. Twelve pixels is enough to read as "this
  /// went away" while the width itself carries the movement.
  static const double _drift = 12;

  /// One rail's share of the crossfade. Each is alone for the first and last
  /// quarter of the fold and they trade over the middle half, so neither is
  /// ever the only thing on screen at half strength.
  static double _fade(double t) => ((t - 0.25) / 0.5).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    // The surface below is this widget's, so it needs its own subscription —
    // its children each carry theirs and none of them reach up here.
    AppTheme.watch(context);
    final wide = _fade(open);
    final mini = _fade(1 - open);

    return SizedBox(
      width: lerpDouble(AppSidebarMini.width, AppSidebar.width, open),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.sidebarFill,
          border: Border(right: BorderSide(color: AppPalette.divider)),
        ),
        child: ClipRect(
          child: Stack(
            children: [
              // Both rails hang off the left edge, which is the edge that
              // doesn't move: pinning the wide one to the right instead would
              // slide its icons out of view first and leave a column of
              // orphaned labels.
              //
              // Unmounted at zero opacity rather than merely invisible: the
              // wide rail carries the chat list and the project tree, and a
              // folded rail should not be paying for them.
              if (wide > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: AppSidebar.width,
                  child: Opacity(
                    opacity: wide,
                    child: Transform.translate(
                      offset: Offset(-_drift * (1 - open), 0),
                      child: const AppSidebar(),
                    ),
                  ),
                ),
              if (mini > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: AppSidebarMini.width,
                  child: Opacity(
                    opacity: mini,
                    child: Transform.translate(
                      offset: Offset(-_drift * open, 0),
                      child: const AppSidebarMini(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
