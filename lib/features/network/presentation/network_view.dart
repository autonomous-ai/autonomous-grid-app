import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/network_providers.dart';

/// Shows the selected network's details — read straight from `~/.grid`
/// (credential + optional local server config). Read-only for now; mutations
/// (create/join/allowlist) land in a later slice.
class NetworkView extends ConsumerWidget {
  const NetworkView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    final config = ref.watch(selectedNetworkConfigProvider);

    if (network == null) {
      return const SectionScaffold(
        title: 'Network',
        child: ComingSoon(message: 'No network joined yet.'),
      );
    }

    return SectionScaffold(
      title: 'Network',
      subtitle: network.name,
      child: ListView(
        children: [
          InfoRow(label: 'Name', value: network.name),
          InfoRow(label: 'Network ID', value: network.networkId, mono: true),
          InfoRow(label: 'Type', value: network.networkType),
          InfoRow(label: 'Signaling URL', value: network.lanSignalingUrl, mono: true),
          InfoRow(label: 'Relay base', value: network.relayBaseUrl, mono: true),
          InfoRow(
            label: 'Roles',
            value: network.roles.isEmpty ? '—' : network.roles.join(', '),
          ),
          InfoRow(
            label: 'Scopes',
            value: network.scopes.isEmpty ? '—' : network.scopes.join(', '),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),
          if (config == null)
            const InfoRow(
              label: 'Local server',
              value: 'Hosted network — no local server to manage.',
            )
          else ...[
            InfoRow(
              label: 'Server PID',
              value: config.hasServerPid ? '${config.serverPid}' : 'stopped',
            ),
            InfoRow(
              label: 'Sync PID',
              value: config.hasSyncPid ? '${config.syncPid}' : 'stopped',
            ),
            InfoRow(label: 'Postgres', value: config.postgresContainer, mono: true),
          ],
        ],
      ),
    );
  }
}
