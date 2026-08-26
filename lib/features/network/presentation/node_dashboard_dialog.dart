import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_power_provider.dart';
import '../logic/node_dashboard_layout.dart';
import '../logic/node_dashboard_view.dart';
import 'node_dashboard_card.dart';
import 'node_dashboard_toolbar.dart';
import 'share_grid_dialog.dart';

/// Opens the node dashboard — every machine on this grid with its live readings.
///
/// A dialog rather than a shell destination on purpose: the entry point is the
/// grid pill in the header, which is reachable from every screen, and a
/// destination would have meant leaving whatever the person was doing to look at
/// a gauge.
Future<void> showNodeDashboard(BuildContext context) => showDialog<void>(
  context: context,
  // The same scrim the app's other full dialogs dim behind, rather than
  // Material's heavier default.
  barrierColor: const Color(0x66000000),
  builder: (_) => const NodeDashboardDialog(),
);

/// The dashboard surface: one [NodeDashboardCard] per node, refreshed by the
/// same overview poll the rest of the app reads, so opening this never starts a
/// second timer or a second source of truth.
class NodeDashboardDialog extends ConsumerWidget {
  const NodeDashboardDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final nodes = ref.watch(gridOnlineNodesProvider);
    final view = ref.watch(nodeDashboardViewProvider);
    // Two lists on purpose. The cards render [shown]; the toolbar and the header
    // are given [nodes], because a filter's own menu must keep offering what the
    // grid has rather than what is left after it — see [NodeDashboardToolbar].
    final shown = applyNodeDashboardView(nodes, view);
    return Dialog(
      backgroundColor: AppPalette.windowBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppCard.radius),
        side: BorderSide(color: AppCard.hair),
      ),
      child: ConstrainedBox(
        // A grid of cards wants the room; a sentence and two buttons do not.
        // Holding 1180 for an empty grid drew a near-empty pane the width of the
        // window, which reads as a dashboard that failed to load rather than as
        // a grid with nothing on it yet.
        constraints: BoxConstraints(
          maxWidth: nodes.isEmpty ? 460 : 1180,
          maxHeight: 860,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogHeader(total: nodes.length, shown: shown.length),
              if (nodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                NodeDashboardToolbar(nodes: nodes),
              ],
              const SizedBox(height: 16),
              Flexible(
                child: switch ((nodes.isEmpty, shown.isEmpty)) {
                  (true, _) => const _EmptyState(),
                  // Machines are serving, the filters just don't want any of
                  // them — a different fact, and one with a way out.
                  (false, true) => const _NoMatchState(),
                  (false, false) => _NodeGrid(nodes: shown),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cards, laid out in rows that each take the height their tallest card
/// needs.
///
/// **Not a `GridView`, and the reason is a bug this replaced.** A grid tile has
/// to be given its height up front — `mainAxisExtent`, or an aspect ratio — and
/// any figure chosen there is a guess about content that varies per node: a
/// machine reporting three gauges, four detail fields and a throughput footer is
/// taller than one reporting a size and a sentence. The guess was 300px and the
/// fullest cards overflowed it by 22, clipping the tok/s figure off the bottom.
/// Raising the number would only move the cliff.
///
/// Rows are built lazily, so this keeps what the grid was chosen for: a dashboard
/// of many machines still builds only the rows on screen.
class _NodeGrid extends StatelessWidget {
  const _NodeGrid({required this.nodes});

  final List<OverviewNode> nodes;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = dashboardColumns(constraints.maxWidth);
        final rowCount = (nodes.length + columns - 1) ~/ columns;
        return ListView.builder(
          itemCount: rowCount,
          itemBuilder: (_, row) {
            final first = row * columns;
            final cards = nodes.skip(first).take(columns).toList();
            return Padding(
              padding: EdgeInsets.only(
                bottom: row == rowCount - 1 ? 0 : kNodeCardGap,
              ),
              // `IntrinsicHeight` + `stretch`: every card in a row takes the
              // height of the tallest, so their footers sit on one line and the
              // row reads as a set rather than a ragged edge. It measures its
              // children twice, which is affordable here — a row holds at most a
              // handful of cards, and only visible rows are ever built.
              //
              // Still no card declares a height of its own: the row's height is
              // whatever its content needs, which is what keeps the 22px
              // overflow from the fixed-extent grid from coming back.
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: kNodeCardGap),
                      Expanded(
                        child: i < cards.length
                            // A trailing gap in the last row is an empty cell,
                            // so the final card keeps its column width instead
                            // of stretching across the leftovers.
                            ? NodeDashboardCard(node: cards[i])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.total, required this.shown});

  /// Machines serving this grid, and how many of them the filters let through.
  final int total;
  final int shown;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nodes',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              // Says "serving", not "N of M online": the relay lists only nodes
              // whose heartbeat is still live, so every card below is online by
              // construction and a ratio would always read N of N.
              //
              // The ratio that *is* printed is a different one — cards shown out
              // of machines serving — and only while a filter is on. The count
              // has to follow what the dashboard is actually showing, or the one
              // line naming a number contradicts the cards under it.
              Text(
                nodeDashboardSubtitle(total, shown),
                style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
              ),
            ],
          ),
        ),
        // [AppIconButton], not a bare [IconButton]: the raw one keeps Material's
        // 48px tap padding and its own hover grey, so it sat further from the
        // dialog's edge than every other close in the app and lit differently
        // on hover. 18 is the size a dialog's close is drawn at.
        AppIconButton(
          icon: Icons.close,
          size: 18,
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Machines are serving, but none of them answer the filters in force.
///
/// Its own state rather than the empty grid's, because the two are opposite
/// facts and only one of them is the user's to fix: an empty grid needs a
/// machine joined to it, and this needs a button pressed. Telling somebody to go
/// join a machine to a grid that already has nine is the kind of wrong advice
/// that costs an afternoon.
///
/// [EmptyState] rather than a private column, and not [EmptyState.noMatches]
/// either: that constructor is deliberately actionless because the usual fix for
/// a filter is to retype the query, and here there is a button that does it.
class _NoMatchState extends ConsumerWidget {
  const _NoMatchState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'No machine matches',
      message:
          'Every machine on this grid is filtered out by what you asked '
          'for.',
      action: TextButton(
        onPressed: ref.read(nodeDashboardViewProvider.notifier).clearFilters,
        child: const Text('Show all machines'),
      ),
    );
  }
}

/// A grid with nothing serving it yet.
///
/// It used to print a second sentence of the fact the header had already given
/// ("No machines are serving this grid right now" above, "Nothing to show yet"
/// below) and then stop. Two statements of one fact and no way out of it — the
/// state §5 asks to be *actionable*.
///
/// So the header keeps the fact and this keeps the next step, and the step is
/// the same pair the top bar offers, because a grid grows in exactly two ways:
/// this computer joins it, or somebody else's does. The engine half is gated on
/// [NetworkCredential.canManageProvider] for the reason it always was — a
/// consumer following it would arrive at a screen that only tells them they may
/// not.
///
/// It also sat visibly off-centre, and that was a layout bug rather than a
/// choice: a shrink-wrapping column inside a `crossAxisAlignment: start` parent
/// centres its icon over its own *text width*, not over the dialog.
/// [EmptyState] wraps itself in a [Center] and the question stops arising.
class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final grid = ref.watch(selectedNetworkProvider);
    final canHost = grid?.canManageProvider ?? false;

    // Push the next screen only once this dialog is gone: pushing first and
    // popping after would pop the thing just pushed.
    void openShare() {
      if (grid == null) return;
      final navigator = Navigator.of(context);
      navigator.pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!navigator.mounted) return;
        ShareGridDialog.show(navigator.context, grid);
      });
    }

    void openEngines() {
      ref.read(analyticsProvider).enginesOpened('model_engines_btn');
      ref.read(shellSectionProvider.notifier).select(ShellSection.engines);
      Navigator.of(context).pop();
    }

    return EmptyState(
      icon: LucideIcons.server300,
      title: canHost ? 'Add the first machine' : 'No machines yet',
      message: canHost
          ? "Share this computer's models with the grid, or invite someone "
                'who can share theirs.'
          : 'Invite someone who can run a model for this grid, and their '
                'readings appear here.',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canHost) ...[
            // The screen's own name, not a verb of its own — the top bar's
            // button says this too, and one screen answers to one word (§5).
            FilledButton(
              onPressed: openEngines,
              child: const Text('Model engines'),
            ),
            const SizedBox(width: 8),
          ],
          TextButton(onPressed: openShare, child: const Text('Invite members')),
        ],
      ),
    );
  }
}
