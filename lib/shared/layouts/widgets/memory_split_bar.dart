import 'package:flutter/material.dart';

import '../../../features/network/logic/grid_power_provider.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../copy/plural.dart';
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

/// The grid's memory split, drawn: [SplitBar] with the machine labels and GB
/// figures stripped back to the geometry it needs.
///
/// A thin adapter on purpose. The width maths and the palette live in
/// `grid_theme` because the phone draws this same bar from the projection the
/// desktop sends it, and a second copy of either is how one machine ends up
/// emerald here and violet there.
class MemorySplitBar extends StatelessWidget {
  const MemorySplitBar({super.key, required this.slices, this.height = 6});

  final List<NodeSlice> slices;
  final double height;

  @override
  Widget build(BuildContext context) => SplitBar(
    height: height,
    slices: [
      for (final slice in slices)
        BarSlice(fraction: slice.fraction, color: slice.color),
    ],
  );
}
