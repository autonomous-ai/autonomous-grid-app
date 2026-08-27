import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../network/logic/grid_access_summary.dart';
import '../../../network/logic/grid_choice_row.dart';
import '../../../network/logic/grid_overview_provider.dart';

/// The grids this account can enter, grouped by the reader's standing in them
/// and pressed to select one.
///
/// It used to be a flat list of names with a coloured word on each row, and
/// picking a row entered the grid on the spot. Two things changed. The rows are
/// grouped, because "yours", "you're invited" and "open to anyone" is the same
/// fact the pills carried, said once over a set instead of once per row — and a
/// heading can be scanned past, where a pill on every line cannot. And picking
/// now *selects*: the button in the footer is what ends the screen, so a
/// mis-click costs nothing and the reader can compare two grids before
/// committing to either.
///
/// Each row says what the grid is doing right now, probed per grid. That is the
/// difference between choosing a grid and guessing at one: an account often has
/// several, and the only one worth entering is the one with something answering
/// on it.
class GridPickList extends ConsumerWidget {
  const GridPickList({
    super.key,
    required this.networks,
    required this.selected,
    required this.onSelect,
  });

  /// Already filtered by the search box above, if there is one.
  final List<NetworkCredential> networks;

  /// The grid the footer's button would enter, or null before a choice.
  final NetworkCredential? selected;

  final ValueChanged<NetworkCredential> onSelect;

  /// Roughly five rows, then it scrolls. The account can reach every public
  /// grid on the control plane, so this has to stay a list rather than become
  /// the page.
  static const double _maxHeight = 296;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    if (networks.isEmpty) return const _NoMatches();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _maxHeight),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in groupGrids(networks)) ...[
              _GroupHeading(tag: group.tag, count: group.grids.length),
              for (final network in group.grids) ...[
                _GridRow(
                  network: network,
                  selected: network.networkId == selected?.networkId,
                  onTap: () => onSelect(network),
                ),
                const SizedBox(height: 7),
              ],
              const SizedBox(height: 5),
            ],
          ],
        ),
      ),
    );
  }
}

/// "YOURS · 3" over the grids it counts.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.tag, required this.count});

  final GridAccessTag tag;
  final int count;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            tag.groupLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.09 * 10.5,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: AppFont.semibold,
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// One grid: whether anything is answering on it, its name, what it is doing,
/// and whether it is the one selected.
class _GridRow extends ConsumerStatefulWidget {
  const _GridRow({
    required this.network,
    required this.selected,
    required this.onTap,
  });

  final NetworkCredential network;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_GridRow> createState() => _GridRowState();
}

class _GridRowState extends ConsumerState<_GridRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // Probed per grid, sharing the cache the Grids screen fills — so a row here
    // and a bolt there can never disagree about whether a grid is up.
    final overview = ref.watch(
      gridOverviewForProvider(widget.network.networkId),
    );
    final liveness = switch (overview) {
      AsyncData(:final value) => GridReached(
        running: value.state?.toLowerCase() == 'running',
        nodes: value.stats.nodes,
        models: value.stats.models,
      ),
      AsyncError() => const GridUnreachable(),
      _ => const GridChecking(),
    };
    // The same predicate the sentence under the name uses. It read `running`
    // on its own before, which put a green dot beside a grid reporting itself
    // up with nothing on it — the one row a reader would have picked first.
    final live = gridIsAnswering(liveness);
    final selected = widget.selected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: AppCard.base,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected
                  ? AppPalette.accent
                  : _hovered
                  ? AppPalette.textFaint
                  : AppPalette.divider,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppPalette.accent.withValues(alpha: 0.14),
                      spreadRadius: 3,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              // A dot, not a bolt. The bolt is the app's mark for a grid; here
              // every row is a grid, so the only thing worth a glyph is the one
              // fact that differs between them.
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  color: live ? AppPalette.online : AppPalette.textFaint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.network.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 14,
                        fontWeight: AppFont.semibold,
                        letterSpacing: -0.01 * 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      gridRowMeta(liveness),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.2,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 13),
              _PickMark(selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark saying which grid the footer's button would open.
///
/// A tick in a circle rather than a chevron: a chevron promises that pressing
/// the row *goes* somewhere, which is what these rows used to do and no longer
/// do. This one says "chosen", which is what the press now means.
class _PickMark extends StatelessWidget {
  const _PickMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedContainer(
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: selected ? AppPalette.accent : AppCard.base,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppPalette.accent : AppPalette.divider,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
          : null,
    );
  }
}

/// What the list shows when a search matches nothing.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nothing matches that name.',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13.5,
              fontWeight: AppFont.semibold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Check the spelling, or start a new grid below.',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              height: 1.45,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
