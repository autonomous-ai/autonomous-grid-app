import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/meta_label.dart';
import '../../logic/grid_growth.dart';

/// What the grid on screen adds up to, right now: machines, pooled memory, and
/// what that pool can run — plus one line saying what just happened.
///
/// Read off the same timeline the picture is drawn from, so the numbers are the
/// picture's own arithmetic rather than a second, hopeful set. Each flashes gold
/// as it changes, and that flash *is* the argument; it costs no state, because
/// how recently a machine landed is a fact about the clock.
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
        final fresh = growth.fresh;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Wrap, not Row: this column gets narrow before the window does, and
            // a Row would overflow rather than fold.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 44,
              runSpacing: 14,
              children: [
                _Stat(
                  label: 'Machines',
                  value: '${growth.machines}',
                  fresh: fresh,
                ),
                _Stat(
                  label: 'Memory pooled',
                  value: growth.memoryValue,
                  unit: growth.memoryUnit,
                  fresh: fresh,
                ),
                // The label itself changes. Past a trillion parameters the
                // ladder of model sizes runs out, and what keeps growing
                // honestly is how many copies run at once — printing "2T" would
                // be a claim about a model nobody has published.
                _Stat(
                  label: growth.modelLabel,
                  value: growth.modelValue,
                  unit: growth.modelUnit,
                  fresh: fresh,
                ),
              ],
            ),
            const SizedBox(height: 22),
            _Receipt(growth: growth),
          ],
        );
      },
    );
  }
}

/// Brand gold that can carry type.
///
/// §11 blesses `brandBolt` for rings and haloes and forbids it for small text on
/// a light page, and the measurement is the reason: `#C98A00` on white is
/// **2.950:1** — under the 3:1 even large text needs, and nowhere near the
/// 4.5:1 the 13px receipt line does. Dark is 8.377:1 and keeps the brand token
/// untouched; light drops to the deep gold, which measures **4.68:1** and is the
/// same colour the picture's hot gold takes in light, for the same reason: on a
/// page with no headroom above, gold gets more present by going *deeper*.
///
/// The picture itself keeps `brandBolt` throughout — §11 allows exactly that for
/// graphics, and this is the line it draws.
Color get _goldInk =>
    AppTheme.pick(const Color(0xFF9A6B00), AppPalette.brandBolt);

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

  /// 1 the instant something lands, 0 once the flash has faded.
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
        // of them is flashing; anchored left, a flash nudged the whole row.
        Transform.scale(
          scale: 1 + 0.11 * fresh,
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
              color: fresh > 0.01 ? _goldInk : AppPalette.textPrimary,
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

/// One line of commentary under the rail — what just happened, in words.
///
/// The fact at the end is the half set in gold, and it changes with the act: a
/// machine's name while machines still have names, then a count once they stop
/// having them, then the pool itself. Held to a single line, because a caption
/// that wraps moves the button under it.
class _Receipt extends StatelessWidget {
  const _Receipt({required this.growth});

  final GridGrowth growth;

  @override
  Widget build(BuildContext context) {
    final (sentence, fact) = growth.receipt;
    return Text.rich(
      TextSpan(
        text: sentence,
        children: [
          if (fact.isNotEmpty)
            TextSpan(
              text: ' · $fact',
              style: TextStyle(color: _goldInk, fontWeight: FontWeight.w500),
            ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // `textSecondary`, not `textFaint`: the faint grey lands near 3.3:1 on
      // this ground, and this is a sentence to read rather than a hairline.
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        color: AppPalette.textSecondary,
      ),
    );
  }
}
