import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_overview_provider.dart';
import 'create_network_dialog.dart';
import 'detail_widgets.dart';

/// Middle column: searchable list of joined networks, grouped under the
/// account owner — Tailscale's "Devices" list. Tapping one selects it.
class NetworkList extends ConsumerStatefulWidget {
  const NetworkList({super.key});

  static const double width = 320;

  @override
  ConsumerState<NetworkList> createState() => _NetworkListState();
}

class _NetworkListState extends ConsumerState<NetworkList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final selected = ref.watch(selectedNetworkProvider);
    final owner = session.user['name'] as String? ?? session.userEmail ?? 'My grids';

    // Show every grid the user belongs to — including ones they own/administer
    // (e.g. a grid just created via "+") — so nothing is silently hidden.
    final visible = session.networks;
    final networks = visible
        .where((n) => n.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Container(
      width: NetworkList.width,
      color: AppPalette.windowBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ListHeader(count: visible.length),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search…',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
          ),
          Expanded(
            child: networks.isEmpty
                ? _Empty(hasGrids: visible.isNotEmpty)
                : ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      _GroupHeader(label: owner),
                      for (final n in networks)
                        _NetworkTile(
                          network: n,
                          selected: n.networkId == selected?.networkId,
                          onTap: () => ref
                              .read(selectedNetworkProvider.notifier)
                              .select(n),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 12, 14),
      child: Row(
        children: [
          Text('Grids',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600, fontSize: 20)),
          const SizedBox(width: 8),
          Text('$count',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppPalette.textFaint)),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => CreateNetworkDialog.show(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New grid'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 6),
      child: Text(label,
          style: const TextStyle(
              color: AppPalette.textFaint,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    );
  }
}

class _NetworkTile extends ConsumerWidget {
  const _NetworkTile({
    required this.network,
    required this.selected,
    required this.onTap,
  });

  final NetworkCredential network;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same operational state the detail header shows (shared provider cache):
    // green when a node is serving the grid, muted otherwise — stopped, still
    // loading, or unreachable. Keeps the list dot honest with Running / Stopped.
    final state = ref
        .watch(gridOverviewForProvider(network.networkId))
        .asData
        ?.value
        .state;
    final running = state?.toLowerCase() == 'running';
    final dotColor = running ? AppPalette.online : AppPalette.offline;
    final fg = selected ? Colors.white : AppPalette.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? AppPalette.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                StatusDot(color: dotColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(network.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 8),
                OwnerBadge(network: network),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasGrids});

  /// True when the user has grids but the search filtered them all out — versus
  /// a genuine first-run with no grids at all (each needs different copy).
  final bool hasGrids;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (hasGrids) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No grids match your search.',
              style: TextStyle(color: AppPalette.textSecondary)),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined,
                size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text("You don't have any grids yet",
                style: theme.textTheme.titleSmall, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'A grid is your private network for running and using AI models. '
              'Create one to get started.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => CreateNetworkDialog.show(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create your first grid'),
            ),
          ],
        ),
      ),
    );
  }
}
