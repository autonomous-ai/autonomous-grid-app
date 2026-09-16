/// The card at the top of a grid's screen: which grid this is, whether the
/// computer is working in it, what it can do, and who it is signed in as.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_detail.dart';
import 'grid_overview_sections.dart';
import 'parts.dart';

/// The grid itself: whether the computer is working in it, what it can do, and
/// who it is signed in as.
class GridSummaryCard extends StatelessWidget {
  const GridSummaryCard(this.grid, {super.key});

  final GridDetail grid;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final overview = grid.overview;
    return GridCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Green only for the grid the computer is actually in. Three
              // grids all showing a live dot would say this machine is working
              // in three places at once, which is not a thing (§5).
              GridDot(live: grid.current),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  grid.name.isEmpty ? grid.id : grid.name,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (overview != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GridFacts(meta: overview.meta, can: overview.can),
            ),
          const SizedBox(height: 10),
          _Field(label: 'Kind', value: grid.type),
          _Field(label: 'Signed in as', value: grid.email),
          _Field(
            label: 'Right now',
            value: grid.current
                ? 'Your computer is working in this grid'
                : 'Your computer is signed in, but working elsewhere',
          ),
        ],
      ),
    );
  }
}

/// A label and its value, stacked the way a detail row is on the desktop.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppPalette.textFaint,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
