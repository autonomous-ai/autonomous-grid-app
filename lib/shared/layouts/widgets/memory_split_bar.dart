import 'package:flutter/material.dart';

import '../../../features/network/logic/grid_power_provider.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';

/// One machine's share of the grid's GPU memory: what to draw, what to call it,
/// and how much of the bar it gets.
class NodeSlice {
  const NodeSlice({
    required this.label,
    required this.gb,
    required this.fraction,
    required this.color,
  });

  final String label;
  final double gb;
  final double fraction;
  final Color color;
}

/// Colours for the split bar, in assignment order. Distinct hues rather than
/// shades of one, so neighbouring slices stay tellable apart at 6px tall — the
/// bar is the only place in the app where colour carries identity rather than
/// status, which is why these are local and not palette tokens.
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

/// Builds the bar's slices from the online nodes: the top [kMaxSlices] machines
/// by memory, then everything else collapsed into one "+N more".
///
/// Nodes reporting no VRAM are excluded — they contribute nothing to the total
/// and drawing them as zero-width slivers would only add legend rows for
/// machines with nothing to show in this bar.
List<NodeSlice> buildMemorySlices(List<OverviewNode> nodes, double totalGb) {
  final withVram = <({String name, double gb})>[
    for (final node in nodes)
      if (nodeVramGb(node) case final gb?) (name: node.name, gb: gb),
  ];
  if (withVram.isEmpty || totalGb <= 0) return const [];

  final labels = shortenNodeNames([for (final n in withVram) n.name]);
  final slices = <NodeSlice>[];
  final shown = withVram.length <= kMaxSlices ? withVram.length : kMaxSlices;

  for (var i = 0; i < shown; i++) {
    slices.add(
      NodeSlice(
        label: labels[i],
        gb: withVram[i].gb,
        fraction: withVram[i].gb / totalGb,
        color: sliceColor(i),
      ),
    );
  }

  final rest = withVram.skip(shown);
  if (rest.isNotEmpty) {
    final restGb = rest.fold<double>(0, (sum, n) => sum + n.gb);
    slices.add(
      NodeSlice(
        label: '+${rest.length} more ${plural(rest.length, 'machine')}',
        gb: restGb,
        fraction: restGb / totalGb,
        color: sliceColor(kMaxSlices),
      ),
    );
  }
  return slices;
}

/// The stacked bar: one strip of colour per machine, sized to its share of the
/// grid's GPU memory.
///
/// Slices butt directly against each other. An earlier version separated them
/// with a 2px gap, which cost the *smallest* slice most — a 7% share of a 246px
/// bar is only ~17px wide, and losing 2px of it to a gap on each side left
/// barely a tick of colour. Distinct hues already do the separating.
class MemorySplitBar extends StatelessWidget {
  const MemorySplitBar({super.key, required this.slices, this.height = 6});

  final List<NodeSlice> slices;
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
              // space — a failure invisible to a widget test that only checks
              // the slices exist.
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
