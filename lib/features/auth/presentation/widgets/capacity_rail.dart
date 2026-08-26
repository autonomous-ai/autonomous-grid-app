import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/meta_label.dart';
import '../../logic/grid_growth.dart';

/// What the grid on screen adds up to, right now: machines, pooled memory, and
/// the largest model that pool can hold.
///
/// Read off the same timeline the picture is drawn from, so the numbers are the
/// picture's own arithmetic rather than a second, hopeful set. Each flashes gold
/// as it changes — that flash *is* the argument, and it costs no state: how
/// recently a machine landed is a fact about the clock.
///
/// Deliberately not faded at the seam of the loop, unlike the picture: the rail
/// is a readout, and one that blinks out every turn is harder to read than one
/// that simply counts up again.
class CapacityRail extends StatelessWidget {
  const CapacityRail({super.key, required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final growth = growthAt(animation.value * kWelcomeLoopSeconds);
        final fresh = (1 - growth.sinceLastJoin / 0.45).clamp(0.0, 1.0);
        // Wrap, not Row: these three sit inside a card that gets narrow before
        // the window does, and a Row would overflow rather than fold.
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: 44,
          runSpacing: 14,
          children: [
            _Stat(label: 'Machines', value: '${growth.machines}', fresh: fresh),
            _Stat(
              label: 'Memory pooled',
              value: '${growth.pooledGb}',
              unit: 'GB',
              fresh: fresh,
            ),
            _Stat(
              label: 'Largest model',
              value: '${growth.largestModelB}',
              unit: 'B',
              fresh: fresh,
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.fresh,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  /// 1 the instant a machine joins, 0 once the flash has faded.
  final double fresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        MetaLabel(label),
        const SizedBox(height: 5),
        // Grows about its own centre so the three stay evenly spaced while one
        // of them is flashing; anchored left, a flash nudged the row.
        Transform.scale(
          scale: 1 + 0.12 * fresh,
          alignment: Alignment.center,
          child: Text.rich(
            TextSpan(
              text: value,
              children: [
                if (unit != null)
                  TextSpan(
                    text: unit,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppPalette.textSecondary,
                    ),
                  ),
              ],
            ),
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.6,
              height: 1,
              color: Color.lerp(
                AppPalette.textPrimary,
                AppPalette.brandBolt,
                fresh,
              ),
              // The numbers climb while the eye is on them; without this the
              // whole rail shifts sideways every time a digit changes width.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
