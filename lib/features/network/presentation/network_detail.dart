import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/delete_network_controller.dart';
import '../logic/grid_overview_provider.dart';
import 'add_member_dialog.dart';
import 'consumer_env_card.dart';
import 'detail_widgets.dart';
import 'grid_overview_card.dart';
import 'members_tab.dart';

/// Right-hand detail pane for the selected network — Tailscale device-detail
/// style: a status header over the grid's content. Admins and providers get a
/// tabbed view (Overview / Members) so they can manage who's on the grid.
class NetworkDetail extends ConsumerWidget {
  const NetworkDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
      child: _Header(network: network),
    );

    // Member management (the Members tab) is owner-only — the control plane
    // doesn't support member admin for providers yet. Everyone else, providers
    // included, gets just the overview.
    if (!network.isOwner) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [header, Expanded(child: _OverviewTab(network: network))],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            tabs: [Tab(text: 'Overview'), Tab(text: 'Members')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(network: network),
                MembersTab(network: network),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The grid's overview content (stats, connection, role-specific cards, and
/// actions) — the default tab, also shown on its own for non-admins.
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      children: [
        // Headline stats stay pinned under the running status.
        const GridStatsSection(),
        // What the grid can actually do (Chat / Images / Video) — the only place
        // a media capability shows, since it isn't a listed model.
        const GridCapabilitiesSection(),
        const SizedBox(height: 22),
        // API access first: the credentials a developer needs to call this grid.
        ConsumerEnvCard(network: network),
        // Then the models they can call, and the nodes serving them. Each adds
        // its own leading gap and collapses to nothing when empty.
        const GridModelsSection(),
        const GridNodesSection(),
        // "Set up engine" is provider-only; the quick "Test" action now lives in
        // the header. Consumers have no body action, so skip the spacing too.
        if (network.canManageProvider) ...[
          const SizedBox(height: 20),
          const _Actions(),
        ],
        // Owner-only, pinned to the bottom: permanently delete this grid.
        if (network.isOwner) ...[
          const SizedBox(height: 28),
          _DeleteGridButton(network: network),
        ],
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The grid's live operational state from its API: "running" when a node is
    // serving it, anything else (stopped, still loading, or unreachable) reads
    // as Stopped. One operational vocabulary — never the access-token state.
    final state = ref.watch(gridOverviewProvider).asData?.value.state;
    final running = state?.toLowerCase() == 'running';
    final label = running ? 'Running' : 'Stopped';
    final color = running ? AppPalette.online : AppPalette.offline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Title + badges take the remaining width (name ellipsizes) so the
            // header actions pin to the top-right, like page-level actions.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(network.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600, fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  GridBadges(network: network),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Add member is owner-only (BE doesn't support member admin for
            // providers yet); it sits beside Test so it's reachable from any tab.
            if (network.isOwner) ...[
              _AddMemberButton(network: network),
              const SizedBox(width: 8),
            ],
            const _TestModelButton(),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            StatusDot(color: color, size: 9),
            const SizedBox(width: 8),
            Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          ],
        ),
      ],
    );
  }
}

/// Provider-only body action: jump to the Engines tab to set up an engine (the
/// real "Start engine" lives there once a model is ready — hence "Set up", not
/// "Start"). Gated on the provider role by its call site.
class _Actions extends ConsumerWidget {
  const _Actions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: () =>
              ref.read(navSectionProvider.notifier).select(NavSection.provider),
          icon: const Icon(Icons.dns_outlined, size: 18),
          label: const Text('Set up engine'),
        ),
      ],
    );
  }
}

/// The grid's header action: opens the quick model-test chat dialog. Lives
/// top-right so it's always within reach whichever tab you're on.
class _TestModelButton extends ConsumerWidget {
  const _TestModelButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton.icon(
      onPressed: () => openPlaygroundDialog(context, ref),
      icon: const Icon(Icons.chat_bubble_outline, size: 16),
      label: const Text('Test'),
    );
  }
}

/// Admin/provider header action: opens the invite-member dialog. Sits beside
/// Test so member management is reachable from any tab, not just Members.
class _AddMemberButton extends StatelessWidget {
  const _AddMemberButton({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => AddMemberDialog.show(context, network.networkId),
      icon: const Icon(Icons.person_add_alt_1, size: 16),
      label: const Text('Add member'),
    );
  }
}

/// Owner-only destructive action at the bottom of the detail: permanently
/// deletes the grid via the control plane (after a confirm). On success the
/// synced list drops it and the selection falls back to another grid.
class _DeleteGridButton extends ConsumerWidget {
  const _DeleteGridButton({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleting =
        ref.watch(deleteNetworkControllerProvider) is DeleteNetworkDeleting;
    // Its own block: a divider sets it apart, and the affordance stays small +
    // muted so it doesn't compete with the primary content — it only reads as
    // "danger" once tapped (the confirm dialog).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: AppPalette.divider),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: deleting ? null : () => _confirmAndDelete(context, ref),
          style: TextButton.styleFrom(
            foregroundColor: AppPalette.textFaint,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 12),
          ),
          icon: deleting
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.delete_outline, size: 14),
          label: Text(deleting ? 'Deleting…' : 'Delete grid'),
        ),
      ],
    );
  }

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Delete this grid?'),
          content: Text(
            'This permanently deletes "${network.name}" and removes everyone '
            "on it. This can't be undone.",
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final name = network.name;
    final error = await ref
        .read(deleteNetworkControllerProvider.notifier)
        .delete(network.networkId);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? 'Deleted "$name".')),
    );
  }
}
