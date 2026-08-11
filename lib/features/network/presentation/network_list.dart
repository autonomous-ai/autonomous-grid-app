import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/toast.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_overview_provider.dart';
import '../logic/grid_sync_controller.dart';
import 'create_network_dialog.dart';
import '../../../shared/widgets/detail_widgets.dart';

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
      color: AppSurface.recess,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ListHeader(count: visible.length),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              // The macOS control font, matching the buttons in the header
              // above. See [kFieldTextStyle].
              style: kFieldTextStyle,
              decoration: const InputDecoration(
                hintText: 'Search…',
                // The field's glyph scale, not the button's — see
                // [kFieldIconSize].
                prefixIcon: Icon(Icons.search, size: kFieldIconSize),
              ),
            ),
          ),
          Expanded(
            child: networks.isEmpty
                ? _Empty(hasGrids: visible.isNotEmpty)
                : _GroupedList(networks: networks, selected: selected),
          ),
        ],
      ),
    );
  }
}

/// The list, split into the grids you own and the ones you merely joined.
///
/// Two different relationships, so they read as two groups — and once the
/// heading says "Mine", the row beneath it no longer needs an "Owner" badge to
/// say the same thing. A group with nothing in it renders nothing at all, so an
/// account with only joined grids sees one plain list rather than an empty
/// heading. That's also why the headings are dropped entirely when only one
/// group has members: a lone "Joined" over every row labels nothing.
///
/// [ListView] rather than a Column: the list is unbounded (a search can widen it
/// again) and this is the one place in the pane that genuinely scrolls.
class _GroupedList extends ConsumerWidget {
  const _GroupedList({required this.networks, required this.selected});

  final List<NetworkCredential> networks;
  final NetworkCredential? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = networks.where((n) => n.isOwner).toList();
    final joined = networks.where((n) => !n.isOwner).toList();
    final grouped = mine.isNotEmpty && joined.isNotEmpty;

    Widget tile(NetworkCredential n) => _NetworkTile(
      network: n,
      selected: n.networkId == selected?.networkId,
      // The heading already says which group this is, so the row's badge would
      // only repeat it. Without a heading (a single-group list) the badge is
      // the only thing left saying it, so it stays.
      showRole: !grouped,
      onTap: () => ref.read(selectedNetworkProvider.notifier).select(n),
    );

    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      children: [
        if (grouped) ...[
          _GroupHeading(label: 'Mine', count: mine.length),
          for (final n in mine) tile(n),
          _GroupHeading(label: 'Joined', count: joined.length),
          for (final n in joined) tile(n),
        ] else
          for (final n in networks) tile(n),
      ],
    );
  }
}

/// A group's heading — the label, and how many rows sit under it.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 5),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 11,
              fontWeight: AppFont.medium,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 11,
              fontWeight: AppFont.medium,
              fontFeatures: AppFont.tabularFigures,
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
          Text(
            'Grids',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textFaint,
            ),
          ),
          const Spacer(),
          const _SyncButton(),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: () => CreateNetworkDialog.show(context),
            icon: const Icon(Icons.add, size: AppControl.iconSize),
            label: const Text('New grid'),
            // Inline in the tight list header, beside the sync icon — the
            // compact scale keeps the row from growing around it. The icon
            // variant of the padding, so the "+" doesn't sit tight to the rim;
            // see [AppControl.paddingSmallIcon].
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, AppControl.heightSmall),
              padding: AppControl.paddingSmallIcon,
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
      switch (next) {
        case GridSyncDone():
          ToastScope.show(
            context,
            const ToastSpec(
              message: 'Grids up to date.',
              severity: ToastSeverity.success,
            ),
          );
        case GridSyncFailed(:final message):
          ToastScope.show(
            context,
            ToastSpec(message: message, severity: ToastSeverity.error),
          );
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
        child: Center(child: AppSpinner(size: SpinnerSize.large)),
      );
    }
    return IconButton(
      tooltip: 'Sync grids',
      visualDensity: VisualDensity.compact,
      // The control glyph size, matching "New grid" beside it — this one was a
      // step larger, so the quieter of the two icons drew the eye first.
      icon: const Icon(Icons.sync, size: AppControl.iconSize),
      onPressed: () => ref.read(gridSyncControllerProvider.notifier).sync(),
    );
  }
}

class _NetworkTile extends ConsumerWidget {
  const _NetworkTile({
    required this.network,
    required this.selected,
    required this.onTap,
    this.showRole = true,
  });

  final NetworkCredential network;
  final bool selected;
  final VoidCallback onTap;

  /// Whether to draw the role badge. False under a group heading that already
  /// names the role — see [_GroupedList].
  final bool showRole;

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

    // Finder's selected row, not a filled button: a quiet wash plus an accent
    // edge. The old accent-filled row forced white text and a white-on-accent
    // badge — three competing layers on the one row you're already looking at,
    // and the heaviest mark in a column you read by scanning names.
    //
    // The accent edge is load-bearing, not decoration. Measured on this column's
    // ground, [AppSurface.hoverFill] and [selectedFill] land 6/255 apart in
    // *both* palettes (light #F0F0F0 vs #EAEAEA, dark #242424 vs #2A2A2A) —
    // below what the eye separates, so on fill alone a hovered row and the open
    // one read identically. The edge is the only thing saying "open" (contrast
    // vs the selected fill: 4.6:1 light, 2.6:1 dark); the fill just warms the row
    // under the pointer. Don't drop it as redundant.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? AppSurface.selectedFill : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          // The edge fades rather than blinking from one row to the next: it is
          // the only mark saying which grid is open (the fills are 6/255 apart —
          // see above), so when it jumps, the answer to "which one am I on?"
          // teleports. Crossing it over the app's hover beat keeps the eye on it.
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  color: selected ? AppPalette.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Padding(
              // The 2px accent edge eats into the leading pad, so take it back
              // here — the glyph must not shift when a row is selected.
              padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.bolt, size: AppControl.iconSize, color: markColor),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      network.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13.5,
                        fontWeight: selected ? AppFont.medium : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (showRole && network.role == NetworkRole.admin) ...[
                    const SizedBox(width: 8),
                    GridBadge(network: network),
                  ],
                ],
              ),
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
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No grids match your search.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt,
              size: 36,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              "You don't have any grids yet",
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'A grid is your private network for running and using AI models. '
              'Create one to get started.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => CreateNetworkDialog.show(context),
              icon: const Icon(Icons.add, size: AppControl.iconSize),
              label: const Text('Create your first grid'),
            ),
          ],
        ),
      ),
    );
  }
}
