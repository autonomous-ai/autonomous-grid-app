import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import 'grid_canvas.dart';
import 'grid_growth_painter.dart';

/// The welcome screen's one picture: computers arriving, wiring themselves into
/// a single grid, and that grid outgrowing the frame.
///
/// It is the argument of the screen, not decoration — "every machine makes it
/// stronger" is a claim, and this is the demonstration running beside it. Which
/// is why the numbers under it come off the same clock the machines do: they
/// cannot say more than the picture shows.
///
/// Pure decoration to a screen reader, though — everything it says that is
/// actually information is repeated as real text in the rail below, so the
/// canvas itself is excluded rather than described.
class GridGrowthBand extends StatelessWidget {
  const GridGrowthBand({super.key, required this.animation});

  /// The screen's timeline, 0 → 1 across one turn.
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // No box around it: on a screen this is the *whole* upper half of, a rim and
    // a recessed fill would draw a frame around the one thing that is supposed
    // to feel like it has no edges. It sits straight on the window ground, over
    // the same backdrop the rest of the pre-app screens use.
    //
    // No `AnimatedBuilder` either, deliberately. The painter repaints off the
    // animation directly, so this widget rebuilds only when the theme flips or
    // the window resizes — which is what lets the painter keep its laid-out text
    // and its position buffers between frames instead of rebuilding them sixty
    // times a second.
    return RepaintBoundary(
      child: ExcludeSemantics(
        child: CustomPaint(
          painter: GridGrowthPainter(
            clock: animation,
            colors: GridPalette.resolve(),
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
