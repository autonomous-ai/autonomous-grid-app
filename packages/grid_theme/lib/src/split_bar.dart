import 'package:flutter/material.dart';

import '../grid_theme.dart';

/// Colours for a split bar, in assignment order. Distinct hues rather than
/// shades of one, so neighbouring slices stay tellable apart at 6px tall — a
/// split bar is the only place in either app where colour carries identity
/// rather than status, which is why these live here and not in [AppPalette].
///
/// Ten, not the five it started with. A real grid runs more machines than five,
/// and every one past the palette fell to the same grey, so a ten-node grid
/// arrived half-named and half-anonymous — the colour said "you are one of the
/// leftovers" about machines the list was giving a full row each.
///
/// Ten hues cannot sit evenly on the wheel, so the pairs that end up close —
/// accent blue/indigo, emerald/cyan/teal — are told apart by lightness instead,
/// and kept far apart in this order, which is also the order they are laid down
/// side by side in the bar. Nothing here may be a grey: [sliceColor] spends grey
/// on the machines that ran out of colours, and a slice that borrowed it would
/// read as one of them.
///
/// In this package rather than in either app because **both draw this bar off
/// the same data**: the desktop from the grid overview it fetched, the phone
/// from the projection the desktop sent it. The index decides the colour on both
/// sides, so one machine that is emerald on the computer has to be emerald on
/// the phone — two copies of this list is how that stops being true.
const List<Color> kSliceColors = [
  Color(0xFF34D399), // emerald
  Color(0xFF2F5BEA), // the app accent
  Color(0xFF8B5CF6), // violet
  Color(0xFFF5A524), // amber
  Color(0xFF22D3EE), // cyan
  Color(0xFFEC4899), // pink
  Color(0xFF84CC16), // lime
  Color(0xFFF87171), // coral
  Color(0xFF6366F1), // indigo
  Color(0xFF0D9488), // teal
];

/// How many machines get their own slice before the rest collapse into one:
/// exactly as many as there are colours.
///
/// Derived rather than written down, because the two drifting apart breaks the
/// bar quietly in both directions — a slice past the palette would be drawn in
/// the same grey as the "+N more" bucket it is supposed to be distinct from,
/// and a colour past the last slice would appear in the legend beside a bar
/// that never shows it.
final int kMaxSlices = kSliceColors.length;

/// The colour for a slice at [index], including the "+N more" bucket — past the
/// palette, everything remaining is drawn in one muted grey rather than cycling
/// hues that would falsely imply a machine's identity.
Color sliceColor(int index) =>
    index < kSliceColors.length ? kSliceColors[index] : AppPalette.textFaint;

/// One strip of a [SplitBar]: how much of the bar it gets, and in what colour.
///
/// Deliberately nothing else. What the strip *means* — a machine, its memory,
/// its name — belongs to whichever app is drawing it; this is the geometry.
class BarSlice {
  const BarSlice({required this.fraction, required this.color});

  /// This strip's share of the whole, 0–1.
  final double fraction;

  /// What to draw it in — normally [sliceColor] of the strip's index.
  final Color color;
}

/// A stacked bar: one strip of colour per slice, sized to its share.
///
/// Slices butt directly against each other. An earlier version separated them
/// with a 2px gap, which cost the *smallest* slice most — a 7% share of a 246px
/// bar is only ~17px wide, and losing 2px of it to a gap on each side left
/// barely a tick of colour. Distinct hues already do the separating.
class SplitBar extends StatelessWidget {
  const SplitBar({super.key, required this.slices, this.height = 6});

  /// The strips, in the order they are laid down.
  final List<BarSlice> slices;

  /// How tall to draw it.
  final double height;

  /// The narrowest a slice may be drawn. Below this a machine's colour reads as
  /// a rendering artefact rather than a share of the grid, so a small provider
  /// is over-represented on purpose — presence matters more than precision at
  /// this size, and the legend carries the exact figure anyway.
  static const double minSliceWidth = 6;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final widths = _sliceWidths(constraints.maxWidth);
            return Row(
              // Stretch, so each slice fills the bar's full height. Without it
              // the Row hands its children a loose vertical constraint, a
              // ColoredBox takes the minimum, and the bar renders as empty
              // space.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < slices.length; i++)
                  SizedBox(
                    width: widths[i],
                    child: ColoredBox(color: slices[i].color),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Slice widths for a bar of [totalWidth], each at least [minSliceWidth].
  ///
  /// Any width granted to a slice below the floor is taken back from the slices
  /// above it, in proportion to their size, so the widths still sum to the bar.
  /// The dominant machine gives up a pixel or two; the small one becomes
  /// visible.
  List<double> _sliceWidths(double totalWidth) {
    final raw = [for (final s in slices) s.fraction * totalWidth];
    final belowFloor = [
      for (var i = 0; i < raw.length; i++)
        if (raw[i] < minSliceWidth) i,
    ];
    if (belowFloor.isEmpty) return raw;

    final debt = belowFloor.fold<double>(
      0,
      (sum, i) => sum + (minSliceWidth - raw[i]),
    );
    final donors = [
      for (var i = 0; i < raw.length; i++)
        if (raw[i] >= minSliceWidth) i,
    ];
    final donorTotal = donors.fold<double>(0, (sum, i) => sum + raw[i]);

    // Every slice is under the floor (a very narrow bar, or a great many
    // machines): nothing to take from, so share the bar equally.
    if (donors.isEmpty || donorTotal <= 0) {
      return [for (var i = 0; i < raw.length; i++) totalWidth / raw.length];
    }

    return [
      for (var i = 0; i < raw.length; i++)
        if (raw[i] < minSliceWidth)
          minSliceWidth
        else
          raw[i] - debt * (raw[i] / donorTotal),
    ];
  }
}
