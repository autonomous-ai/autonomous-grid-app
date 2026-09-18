/// What the computer is signed in to.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';
import 'grid_detail_screen.dart';
import 'parts.dart';

/// The grids this computer has joined, each a way into what it is serving
/// there and how strong the grid is.
class GridsTab extends StatelessWidget {
  const GridsTab(this.grids, {super.key});

  /// Every grid the computer is signed in to.
  final List<GridRow> grids;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (grids.isEmpty) return const _NoGrids();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      // Short and bounded — this is every grid a person has joined, not a
      // feed. A Column is honest here; a builder would be cargo cult.
      children: [for (final grid in grids) _GridTile(grid)],
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile(this.grid);

  final GridRow grid;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GridListRow(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GridDetailScreen(
            gridId: grid.id,
            title: grid.name.isEmpty ? grid.id : grid.name,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  grid.name.isEmpty ? grid.id : grid.name,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                RowDetail([grid.type, grid.email]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppPalette.textFaint,
          ),
        ],
      ),
    );
  }
}

class _NoGrids extends StatelessWidget {
  const _NoGrids();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          "Your computer isn't signed in to a grid yet. Sign in over there, "
          'then tap refresh.',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
        ),
      ),
    );
  }
}
