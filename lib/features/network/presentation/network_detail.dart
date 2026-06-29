import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/network_status.dart';
import 'consumer_env_card.dart';
import 'detail_widgets.dart';
import 'grid_overview_card.dart';
import 'members_tab.dart';

/// Right-hand detail pane for the selected network — Tailscale device-detail
/// style: a status header over the grid's content. Admins get a tabbed view
/// (Overview / Members) so they can manage who's on the grid.
class NetworkDetail extends ConsumerWidget {
  const NetworkDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = networkConn(network, DateTime.now());
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
      child: _Header(network: network, conn: conn),
    );

    // Member management is owner-only — gate the tab on the admin role.
    if (network.role != NetworkRole.admin) {
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
        const GridOverviewView(),
        const SizedBox(height: 22),
        DetailSection(
          title: 'Connection',
          children: [
            AddressRow(label: 'Grid address', value: network.lanSignalingUrl),
          ],
        ),
        const SizedBox(height: 20),
        if (network.role == NetworkRole.consumer) ...[
          ConsumerEnvCard(network: network),
          const SizedBox(height: 20),
        ],
        _Actions(network: network),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.network, required this.conn});
  final NetworkCredential network;
  final NetworkConn conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = _status(conn);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(network.name,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600, fontSize: 22)),
            ),
            const SizedBox(width: 12),
            RoleBadge(network: network),
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

  (String, Color) _status(NetworkConn conn) {
    return switch (conn) {
      NetworkConn.connected => ('Connected', AppPalette.online),
      NetworkConn.expiringSoon => ('Expiring soon', AppPalette.warn),
      NetworkConn.expired => ('Access expired', AppPalette.offline),
    };
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: () =>
              ref.read(navSectionProvider.notifier).select(NavSection.playground),
          icon: const Icon(Icons.chat_bubble_outline, size: 16),
          label: const Text('Open in Playground'),
        ),
        if (network.canManageProvider)
          OutlinedButton.icon(
            onPressed: () => ref
                .read(navSectionProvider.notifier)
                .select(NavSection.provider),
            icon: const Icon(Icons.podcasts_outlined, size: 16),
            label: const Text('Share a model'),
          ),
      ],
    );
  }
}
