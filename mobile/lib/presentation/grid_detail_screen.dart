/// One grid, opened from the list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_detail.dart';
import 'grid_app_bar.dart';
import 'parts.dart';

/// What this computer is doing on one grid.
class GridDetailScreen extends ConsumerWidget {
  const GridDetailScreen({
    required this.gridId,
    required this.title,
    super.key,
  });

  /// Which grid.
  final String gridId;

  /// What it is called, so the bar has something to say before it loads.
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final detail = ref.watch(gridDetailProvider(gridId));
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      appBar: GridAppBar(title: title.isEmpty ? 'Grid' : title),
      body: detail.when(
        loading: () => Center(
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppPalette.textFaint,
            ),
          ),
        ),
        error: (error, _) => _Problem(
          message: '$error',
          onRetry: () => ref.invalidate(gridDetailProvider(gridId)),
        ),
        data: (grid) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          children: [
            _Summary(grid),
            const SizedBox(height: 24),
            const SectionLabel('Shared from this computer'),
            if (grid.engines.isEmpty)
              const _NothingShared()
            else
              for (final engine in grid.engines) _EngineTile(engine),
          ],
        ),
      ),
    );
  }
}

/// The grid itself, and whether the computer is working in it.
class _Summary extends StatelessWidget {
  const _Summary(this.grid);

  final GridDetail grid;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
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

/// One engine this computer is serving.
class _EngineTile extends StatelessWidget {
  const _EngineTile(this.engine);

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

class _NothingShared extends StatelessWidget {
  const _NothingShared();

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

class _Problem extends StatelessWidget {
  const _Problem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
