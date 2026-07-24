import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/widgets/memory_split_bar.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/grid_power_provider.dart';
import 'grid_overview_widgets.dart';

/// The grid's pooled hardware, on the overview page: how much GPU memory it
/// brings and how that splits across machines, how many requests it serves at
/// once, and how fast.
///
/// The same figures the top-bar pill shows on hover, but persistent and full
/// width here — the overview is where someone comes to answer "is this grid
/// strong enough?", and the split bar answers "one big box or many small ones?"
/// at a glance, which the Nodes list below (one row per machine) can't.
///
/// Hidden entirely when no online node reports any hardware detail — a grid that
/// advertises nothing gets the Nodes list alone, not an empty "power" card.
class GridHardwareSection extends ConsumerWidget {
  const GridHardwareSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final power = ref.watch(gridPowerProvider);
    final nodes = ref.watch(gridOnlineNodesProvider);
    if (!power.hasSpecs) return const SizedBox.shrink();

    final vram = power.vramGb;
    final slices = vram == null
        ? const <NodeSlice>[]
        : buildMemorySlices(nodes, vram);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const SectionHeading(
          title: 'Grid power',
          subtitle:
              'Memory, capacity and speed pooled across the grid’s online '
              'machines.',
        ),
        const SizedBox(height: 12),
        GlassCard(
          style: GlassCardStyle.inset,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (slices.isNotEmpty)
                _MemoryBlock(totalGb: vram!, slices: slices),
              _FooterStats(power: power, hasMemory: slices.isNotEmpty),
            ],
          ),
        ),
      ],
    );
  }
}

/// Graphics memory: the total, one bar split by machine, then a legend naming
/// each machine with its share in GB and percent.
class _MemoryBlock extends StatelessWidget {
  const _MemoryBlock({required this.totalGb, required this.slices});

  final double totalGb;
  final List<NodeSlice> slices;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionLabel(label: 'Graphics memory', trailing: formatVram(totalGb)),
        const SizedBox(height: 10),
        MemorySplitBar(slices: slices, height: 8),
        const SizedBox(height: 10),
        for (final slice in slices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: _LegendRow(slice: slice),
          ),
      ],
    );
  }
}

/// One legend row: a coloured tick echoing the slice, the machine name, then its
/// memory and share right-aligned in fixed columns so the numbers form a column.
class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.slice});

  final NodeSlice slice;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final pct = (slice.fraction * 100).round();
    return Row(
      children: [
        Container(
          width: 3,
          height: 13,
          decoration: BoxDecoration(
            color: slice.color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            slice.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kGridText.copyWith(
              fontSize: 12.5,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 62,
          child: Text(
            formatVram(slice.gb),
            textAlign: TextAlign.right,
            style: kGridNumeral.copyWith(
              fontSize: 12,
              fontWeight: AppFont.medium,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 30,
          child: Text(
            '$pct%',
            textAlign: TextAlign.right,
            style: kGridNumeral.copyWith(
              fontSize: 11,
              color: AppPalette.textFaint,
            ),
          ),
        ),
      ],
    );
  }
}

/// The non-memory figures: requests at a time, and throughput when reported.
/// Sits under a hairline below the memory block (or alone, when no node reports
/// VRAM but does report capacity/speed).
class _FooterStats extends StatelessWidget {
  const _FooterStats({required this.power, required this.hasMemory});

  final GridPower power;
  final bool hasMemory;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final parallel = power.parallel;
    final toks = power.throughputTokS;
    final rows = <Widget>[
      if (parallel != null)
        _StatRow(
          label: 'At a time',
          value: '$parallel',
          unit: plural(parallel, 'request'),
        ),
      if (toks != null)
        _StatRow(label: 'Speed', value: formatThroughput(toks), unit: 'tok/s'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasMemory) ...[
          const SizedBox(height: 12),
          Divider(height: 1, color: AppCard.insetHair),
          const SizedBox(height: 6),
        ],
        ...rows,
      ],
    );
  }
}

/// One "label … value unit" row, matching the pill panel's register so the two
/// surfaces read the same.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: kGridText.copyWith(
                fontSize: 13,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: kGridNumeral.copyWith(
              fontSize: 13,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: 4),
            Text(
              unit!,
              style: kGridText.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small caps label with an optional trailing figure — the memory block's
/// "GRAPHICS MEMORY … 255.9 GB" header.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final style = kGridText.copyWith(
      fontSize: 10.5,
      fontWeight: AppFont.medium,
      letterSpacing: 0.5,
      color: AppPalette.textFaint,
    );
    return Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: style)),
        if (trailing != null)
          Text(
            trailing!,
            style: style.copyWith(
              color: AppPalette.textSecondary,
              letterSpacing: 0,
              fontFeatures: AppFont.tabularFigures,
            ),
          ),
      ],
    );
  }
}
