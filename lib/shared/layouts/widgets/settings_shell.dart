import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/network/presentation/how_to_use_view.dart';
import '../../../features/network/presentation/networks_pane.dart';
import '../../../features/provider_node/presentation/provider_view.dart';
import '../shell_state.dart';
import 'nav_pill.dart';

/// The Settings area: the grid, engine and guide screens the sidebar used to
/// list at the top level, gathered behind one entry so Chat can own the app.
///
/// A slim tab rail on the left switches between them, mirroring the main sidebar
/// so the two feel like one system rather than two nav idioms.
class SettingsShell extends ConsumerWidget {
  const SettingsShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(settingsTabProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsRail(active: tab),
        const VerticalDivider(width: 1),
        Expanded(child: _SettingsContent(tab: tab)),
      ],
    );
  }
}

class _SettingsContent extends StatelessWidget {
  const _SettingsContent({required this.tab});

  final SettingsTab tab;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      SettingsTab.grids => const NetworksPane(),
      SettingsTab.engines => const ProviderView(),
      SettingsTab.howToUse => const HowToUseView(),
    };
  }
}

class _SettingsRail extends ConsumerWidget {
  const _SettingsRail({required this.active});

  final SettingsTab active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 188,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final tab in SettingsTab.values)
              NavPill(
                icon: tab.icon,
                label: tab.label,
                selected: tab == active,
                onTap: () =>
                    ref.read(settingsTabProvider.notifier).select(tab),
              ),
          ],
        ),
      ),
    );
  }
}
