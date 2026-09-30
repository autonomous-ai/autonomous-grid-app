/// What the computer is signed in to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';
import 'grid_detail_screen.dart';
import 'load_states.dart';
import 'parts.dart';

/// The grids this computer has joined, each a way into what it is serving
/// there and how strong the grid is.
class GridsTab extends ConsumerWidget {
  const GridsTab(this.grids, {super.key});

  /// Every grid the computer is signed in to.
  final List<GridRow> grids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return PullToRefresh(
      onRefresh: () => ref.read(phoneLinkProvider.notifier).refresh(),
      scrollable: grids.isNotEmpty,
      child: grids.isEmpty
          ? const EmptyNote(
              "Your computer isn't signed in to a grid yet. Sign in over "
              'there, then pull down to refresh.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              // Short and bounded — this is every grid a person has joined,
              // not a feed. A Column is honest here; a builder would be cargo
              // cult.
              children: [for (final grid in grids) _GridTile(grid)],
            ),
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
