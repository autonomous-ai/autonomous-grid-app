import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/grid_power_provider.dart';
import 'node_dashboard_card.dart';

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

  /// Widest a card gets before the grid adds another column. Sized so a card
  /// keeps its two detail columns readable rather than stretching one row of
  /// labels across a wide display.
  static const double _cardExtent = 340;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final nodes = ref.watch(gridOnlineNodesProvider);
    return Dialog(
      backgroundColor: AppPalette.windowBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppCard.radius),
        side: BorderSide(color: AppCard.hair),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 860),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogHeader(nodes: nodes),
              const SizedBox(height: 16),
              Flexible(
                child: nodes.isEmpty
                    ? const _EmptyState()
                    : GridView.builder(
                        // Lazy, so a grid that grows to dozens of machines
                        // builds only the cards actually on screen.
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: _cardExtent,
                              mainAxisExtent: 300,
                              crossAxisSpacing: 14,
                              mainAxisSpacing: 14,
                            ),
                        itemCount: nodes.length,
                        itemBuilder: (_, index) =>
                            NodeDashboardCard(node: nodes[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.nodes});

  final List<OverviewNode> nodes;

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
              Text(
                nodes.isEmpty
                    ? 'No machines are serving this grid right now.'
                    : '${nodes.length} machine${nodes.length == 1 ? '' : 's'} '
                          'serving · readings refresh with the grid overview',
                style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, size: 18),
          color: AppPalette.textSecondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 26, color: AppPalette.textFaint),
          const SizedBox(height: 10),
          Text(
            'Nothing to show yet — join a machine to this grid and its '
            'readings appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}
