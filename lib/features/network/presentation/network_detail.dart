import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/network_status.dart';
import 'consumer_env_card.dart';
import 'detail_widgets.dart';

/// Right-hand detail pane for the selected network — Tailscale device-detail
/// style: a status header, an endpoints card, and a details card.
class NetworkDetail extends ConsumerWidget {
  const NetworkDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final conn = networkConn(network, now);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      children: [
        _Header(network: network, conn: conn),
        const SizedBox(height: 22),
        DetailSection(
          title: 'Connection',
          children: [
            AddressRow(label: 'Grid ID', value: network.networkId),
            AddressRow(label: 'Server address', value: network.lanSignalingUrl),
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
            onPressed: () =>
                ref.read(navSectionProvider.notifier).select(NavSection.models),
            icon: const Icon(Icons.podcasts_outlined, size: 16),
            label: const Text('Share a model'),
          ),
      ],
    );
  }
}
