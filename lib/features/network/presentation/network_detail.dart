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
        const SizedBox(height: 24),
        _DeveloperSection(network: network),
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
    final nav = ref.read(navSectionProvider.notifier);
    final canProvide = network.canManageProvider;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        // Start engine is the main action for provider-capable grids; pure
        // consumers can't run one, so Playground is their primary action.
        if (canProvide)
          FilledButton.icon(
            onPressed: () => nav.select(NavSection.provider),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Start engine'),
          ),
        _playgroundButton(nav, primary: !canProvide),
      ],
    );
  }

  Widget _playgroundButton(NavSectionNotifier nav, {required bool primary}) {
    void open() => nav.select(NavSection.playground);
    const icon = Icon(Icons.chat_bubble_outline, size: 16);
    const label = Text('Open in Playground');
    return primary
        ? FilledButton.icon(onPressed: open, icon: icon, label: label)
        : OutlinedButton.icon(onPressed: open, icon: icon, label: label);
  }
}

/// Technical details for the grid — IDs, scopes and token epochs — surfaced for
/// every grid so developers can read and copy them straight from the UI. Secret
/// tokens are deliberately omitted (the consumer card reveals the API key).
class _DeveloperSection extends StatelessWidget {
  const _DeveloperSection({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    final expires = _formatEpoch(network.expiresAt);
    return DetailSection(
      title: 'Developer',
      children: [
        AddressRow(label: 'Grid ID', value: network.networkId),
        if (network.nodeId.isNotEmpty)
          AddressRow(label: 'Node ID', value: network.nodeId),
        if (network.deviceId.isNotEmpty)
          AddressRow(label: 'Device ID', value: network.deviceId),
        AddressRow(label: 'Relay base URL', value: network.relayBaseUrl),
        MetaRow(label: 'Network type', value: network.networkType),
        MetaRow(label: 'Roles', value: _orDash(network.roles)),
        MetaRow(label: 'Scopes', value: _orDash(network.scopes)),
        MetaRow(label: 'Member epoch', value: '${network.memberEpoch}'),
        MetaRow(label: 'Network epoch', value: '${network.networkEpoch}'),
        if (expires != null) MetaRow(label: 'Access expires', value: expires),
      ],
    );
  }

  String _orDash(List<String> values) => values.isEmpty ? '—' : values.join(', ');

  /// Unix-seconds → `YYYY-MM-DD HH:MM` local; null for the unset (0) sentinel.
  String? _formatEpoch(int epochSeconds) {
    if (epochSeconds <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
