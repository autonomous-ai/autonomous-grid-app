import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_overview_provider.dart';
import '../logic/grid_sync_controller.dart';
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

    // Show every grid the user belongs to — including ones they own/administer
    // (e.g. a grid just created via "+") — so nothing is silently hidden.
    final visible = session.networks;
    final networks = visible
        .where((n) => n.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Container(
      width: NetworkList.width,
      // A recessed glass well, not an opaque slab — the blurred wallpaper still
      // reads through it so the list column looks "trong trong" like iOS.
      color: AppGlass.recess,
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
                    padding: const EdgeInsets.only(top: 4, bottom: 12),
                    children: [
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
          const _SyncButton(),
          const SizedBox(width: 4),
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

/// Pulls the latest grids from the cloud (`grid sync`) and refreshes the list —
/// the manual counterpart to the automatic sync after create/login. Shows a
/// spinner while running and a one-shot toast on success/failure.
class _SyncButton extends ConsumerWidget {
  const _SyncButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<GridSyncState>(gridSyncControllerProvider, (_, next) {
      final messenger = ScaffoldMessenger.of(context);
      switch (next) {
        case GridSyncDone():
          messenger.showSnackBar(
              const SnackBar(content: Text('Grids up to date.')));
        case GridSyncFailed(:final message):
          messenger.showSnackBar(SnackBar(content: Text(message)));
        case GridSyncIdle():
        case GridSyncRunning():
          break;
      }
    });

    final running = ref.watch(gridSyncControllerProvider) is GridSyncRunning;
    if (running) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: 'Sync grids',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.sync, size: 20),
      onPressed: () => ref.read(gridSyncControllerProvider.notifier).sync(),
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
    // brand gold when a node is serving the grid, muted grey otherwise —
    // stopped, still loading, or unreachable. Keeps the ⚡ mark honest with
    // Running / Stopped, matching the gold/grey bolt in the menu-bar tray list.
    final state = ref
        .watch(gridOverviewForProvider(network.networkId))
        .asData
        ?.value
        .state;
    final running = state?.toLowerCase() == 'running';
    final markColor = running ? AppPalette.brandBolt : AppPalette.offline;
    final fg = selected ? Colors.white : AppPalette.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? AppPalette.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(Icons.bolt, size: 18, color: markColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(network.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 8),
                GridBadge(network: network, onAccent: selected),
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
            Icon(Icons.bolt,
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
