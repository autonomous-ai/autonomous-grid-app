/// What this computer is serving to a grid.
///
/// The half of the grid screen that needs no relay: these records are files
/// under `~/.grid/run/engines`, read by the computer and sent as they are.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_detail.dart';
import 'parts.dart';

/// One engine this computer is serving.
class GridEngineTile extends StatelessWidget {
  const GridEngineTile(this.engine, {super.key});

  final GridEngineRow engine;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GridListRow(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GridDot(live: engine.running),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  engine.models.isEmpty ? engine.id : engine.models.join(' · '),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                RowDetail([
                  // Said plainly rather than left to the dot's colour: a
                  // stopped engine is the ordinary end of `grid join`, not a
                  // fault, and it is worth being able to read.
                  engine.running ? 'Serving' : 'Stopped',
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class GridNothingShared extends StatelessWidget {
  const GridNothingShared({super.key});

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      "Your computer isn't sharing an engine with this grid. Start one in Grid "
      'over there and it will show up here.',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
    );
  }
}
