/// The grid's pooled hardware, on the phone.
///
/// The figures arrive written — "829.1 GB", "~513" — because the rules that
/// decide when gigabytes become terabytes and whether an estimate gets a decimal
/// belong to the computer that measured them. What this file does is lay them
/// out and draw the bar, whose colours come from the shared palette so one
/// machine keeps its colour across both apps.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_overview_view.dart';
import 'parts.dart';

/// The grid's pooled hardware: how much graphics memory it brings, how that
/// splits across machines, and how much work it does at once and how fast.
class GridPowerCard extends StatelessWidget {
  const GridPowerCard(this.power, {super.key});

  /// What the computer measured.
  final GridPowerBlock power;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GridCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (power.split.isNotEmpty) _Memory(power),
          for (var i = 0; i < power.stats.length; i++) ...[
            if (i == 0 && power.split.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: AppCard.hair),
              const SizedBox(height: 6),
            ],
            _Stat(power.stats[i]),
          ],
        ],
      ),
    );
  }
}

/// The memory total, the bar, then a line naming each machine's share.
class _Memory extends StatelessWidget {
  const _Memory(this.power);

  final GridPowerBlock power;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'GRAPHICS MEMORY',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.5,
                  color: AppPalette.textFaint,
                ),
              ),
            ),
            Text(
              power.memory,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Coloured by position out of the shared palette, in the order the
        // computer laid the slices down — so a machine that is emerald over
        // there is emerald here.
        SplitBar(
          height: 8,
          slices: [
            for (var i = 0; i < power.split.length; i++)
              BarSlice(fraction: power.split[i].fraction, color: sliceColor(i)),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < power.split.length; i++)
          _Share(share: power.split[i], color: sliceColor(i)),
      ],
    );
  }
}

/// One machine's line under the bar: its tick, its name, its memory and share.
class _Share extends StatelessWidget {
  const _Share({required this.share, required this.color});

  final GridMemoryShare share;
  final Color color;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              share.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            share.value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              '${(share.fraction * 100).round()}%',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One "label … value unit" figure.
class _Stat extends StatelessWidget {
  const _Stat(this.stat);

  final GridStatRow stat;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              stat.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          Text(stat.value, style: theme.textTheme.bodyMedium),
          if (stat.unit.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              stat.unit,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
