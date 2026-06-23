import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/models/presentation/models_view.dart';
import '../../features/network/presentation/network_view.dart';
import '../../features/onboarding/preflight_providers.dart';
import '../../features/playground/presentation/playground_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../../infrastructure/state/models/network_credential.dart';

/// Which nav section is showing. Index matches [_destinations].
final navIndexProvider = NotifierProvider<NavIndex, int>(NavIndex.new);

class NavIndex extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

const _destinations = [
  (icon: Icons.chat_bubble_outline, label: 'Playground'),
  (icon: Icons.lan_outlined, label: 'Network'),
  (icon: Icons.memory_outlined, label: 'Provider'),
  (icon: Icons.download_outlined, label: 'Models'),
];

/// The main app frame: a left nav rail, the active section, and a status bar.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(navIndexProvider);
    final networks = ref.watch(sessionProvider).networks;
    final selected = ref.watch(selectedNetworkProvider);

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _NavRail(index: index),
                const VerticalDivider(width: 1),
                Expanded(
                  child: IndexedStack(
                    index: index,
                    children: const [
                      PlaygroundView(),
                      NetworkView(),
                      ProviderView(),
                      ModelsView(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _StatusBar(networks: networks, selected: selected),
        ],
      ),
    );
  }
}

class _NavRail extends ConsumerWidget {
  const _NavRail({required this.index});
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NavigationRail(
      selectedIndex: index,
      labelType: NavigationRailLabelType.all,
      onDestinationSelected: (i) =>
          ref.read(navIndexProvider.notifier).select(i),
      destinations: [
        for (final d in _destinations)
          NavigationRailDestination(
              icon: Icon(d.icon), label: Text(d.label)),
      ],
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.networks, required this.selected});

  final List<NetworkCredential> networks;
  final NetworkCredential? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final version = ref.watch(preflightProvider).asData?.value.gridVersion;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Icons.lan_outlined, size: 16),
          const SizedBox(width: 8),
          _NetworkSwitcher(networks: networks, selected: selected),
          const Spacer(),
          if (version != null) Text(version, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _NetworkSwitcher extends ConsumerWidget {
  const _NetworkSwitcher({required this.networks, required this.selected});

  final List<NetworkCredential> networks;
  final NetworkCredential? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (networks.isEmpty) {
      return Text('No network', style: Theme.of(context).textTheme.bodySmall);
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selected?.networkId,
        isDense: true,
        items: [
          for (final n in networks)
            DropdownMenuItem(value: n.networkId, child: Text(n.name)),
        ],
        onChanged: (id) {
          final next = networks.where((n) => n.networkId == id);
          if (next.isNotEmpty) {
            ref.read(selectedNetworkProvider.notifier).select(next.first);
          }
        },
      ),
    );
  }
}
