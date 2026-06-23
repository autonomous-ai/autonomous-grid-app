import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/network_status.dart';
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
    final owner = session.user['name'] as String? ?? session.userEmail ?? 'My networks';

    final networks = session.networks
        .where((n) => n.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Container(
      width: NetworkList.width,
      color: AppPalette.windowBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ListHeader(count: session.networks.length),
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
                ? const _Empty()
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
          Text('Networks',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600, fontSize: 20)),
          const SizedBox(width: 8),
          Text('$count',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppPalette.textFaint)),
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

class _NetworkTile extends StatelessWidget {
  const _NetworkTile({
    required this.network,
    required this.selected,
    required this.onTap,
  });

  final NetworkCredential network;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final conn = networkConn(network, DateTime.now());
    final dotColor = switch (conn) {
      NetworkConn.connected => AppPalette.online,
      NetworkConn.expiringSoon => AppPalette.warn,
      NetworkConn.expired => AppPalette.offline,
    };
    final subtitle =
        Uri.tryParse(network.lanSignalingUrl)?.host ?? network.networkId;
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(network.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: fg,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500)),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.computer,
                              size: 13,
                              color: selected
                                  ? Colors.white70
                                  : AppPalette.textFaint),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: selected
                                  ? Colors.white70
                                  : AppPalette.textSecondary,
                              fontSize: 12,
                              fontFamily: 'monospace')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                RoleBadge(network: network, compact: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No networks match.',
            style: TextStyle(color: AppPalette.textSecondary)),
      ),
    );
  }
}
