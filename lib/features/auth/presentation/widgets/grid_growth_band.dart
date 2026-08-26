import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/grid_growth.dart';
import 'grid_growth_painter.dart';

/// The welcome screen's one picture: computers arriving one by one, wiring
/// themselves into a single grid, and the capacity ring around it filling as
/// they do.
///
/// It is the argument of the screen, not decoration — "every machine makes it
/// stronger" is a claim, and this is the demonstration running beside it. Which
/// is why the ring and the numbers come off the same timeline the machines do
/// (see [growthAt]): they cannot say more than the picture shows.
class GridGrowthBand extends StatelessWidget {
  const GridGrowthBand({super.key, required this.animation});

  /// The screen's timeline, 0 → 1 across one [kWelcomeLoopSeconds] turn.
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // No box around it: on a screen this is the *whole* upper half of, a rim and
    // a recessed fill would draw a frame around the one thing that is supposed
    // to feel like it has no edges. It sits straight on the window ground, over
    // the same backdrop the rest of the pre-app screens use.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => CustomPaint(
          painter: GridGrowthPainter(
            seconds: animation.value * kWelcomeLoopSeconds,
            pill: AppPalette.cardBg,
            hair: AppCard.insetHair,
            bolt: AppPalette.brandBolt,
            online: AppPalette.online,
            label: AppPalette.textSecondary,
            faint: AppPalette.textFaint,
            isDark: AppTheme.isDark,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
