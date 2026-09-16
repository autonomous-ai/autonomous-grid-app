/// One grid, opened from the list.
///
/// Two halves, and they fail independently. The summary and the engines come
/// off the computer's own disk and are always there; the live state — what the
/// grid serves, what it runs on, how strong it is — is the computer's relay call
/// projected for this phone, and it is simply absent when that call could not be
/// made. A grid whose relay is down still opens and still says what this
/// computer is doing on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/grid_detail.dart';
import '../logic/grid_overview_view.dart';
import 'grid_app_bar.dart';
import 'grid_engines_section.dart';
import 'grid_overview_sections.dart';
import 'grid_power_card.dart';
import 'grid_summary_card.dart';
import 'parts.dart';

/// What this computer is doing on one grid, and what the grid itself is.
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
      appBar: GridAppBar(
        title: title.isEmpty ? 'Grid' : title,
        actions: [
          GridBarButton(
            tooltip: 'Refresh',
            icon: Icons.refresh_rounded,
            onPressed: () => ref.invalidate(gridDetailProvider(gridId)),
          ),
        ],
      ),
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
            GridSummaryCard(grid),
            ?_power(grid),
            ?_models(grid),
            ?_nodes(grid),
            const SizedBox(height: 24),
            const SectionLabel('Shared from this computer'),
            if (grid.engines.isEmpty)
              const GridNothingShared()
            else
              for (final engine in grid.engines) GridEngineTile(engine),
          ],
        ),
      ),
    );
  }

  Widget? _power(GridDetail grid) {
    final power = grid.overview?.power;
    if (power == null) return null;
    return _Section(
      label: const SectionLabel(
        'Grid power',
        subtitle: 'Pooled across the machines that are awake right now.',
      ),
      child: GridPowerCard(power),
    );
  }

  Widget? _models(GridDetail grid) {
    final models = grid.overview?.models ?? const <GridModelRow>[];
    if (models.isEmpty) return null;
    return _Section(
      label: const SectionLabel('Models', subtitle: 'Tap one to copy its ID.'),
      child: Column(children: [for (final m in models) GridModelTile(m)]),
    );
  }

  Widget? _nodes(GridDetail grid) {
    final nodes = grid.overview?.nodes ?? const <GridNodeRow>[];
    if (nodes.isEmpty) return null;
    return _Section(
      label: const SectionLabel(
        'Nodes',
        subtitle: 'The machines pooling their power to serve this grid.',
      ),
      child: Column(children: [for (final n in nodes) GridNodeTile(n)]),
    );
  }
}

/// A labelled block, owning the gap above it — every one of these is allowed to
/// be absent, and a spacer left behind by the caller would open a hole on a grid
/// that has nothing to put there.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final Widget label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [label, child],
    ),
  );
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
