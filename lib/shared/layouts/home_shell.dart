import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/models/presentation/models_view.dart';
import '../../features/network/presentation/networks_pane.dart';
import '../../features/playground/presentation/playground_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../theme/app_theme.dart';
import 'shell_state.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/side_nav.dart';

/// The main app frame, Tailscale-style: a full-width title bar on top, a left
/// nav sidebar, and the active section to its right.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(navSectionProvider);

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Column(
        children: [
          const AppTopBar(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SideNav(),
                const VerticalDivider(width: 1),
                Expanded(child: _Content(section: section)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Routes the active nav section to its pane. Networks is a two-column
/// list/detail; the rest render their existing single view. Provider-only
/// sections fall back to Networks when the selected network isn't a provider.
class _Content extends ConsumerWidget {
  const _Content({required this.section});
  final NavSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage =
        ref.watch(selectedNetworkProvider)?.canManageProvider ?? false;
    final effective =
        section.providerOnly && !canManage ? NavSection.networks : section;
    return switch (effective) {
      NavSection.networks => const NetworksPane(),
      NavSection.playground => const PlaygroundView(),
      NavSection.provider => const ProviderView(),
      NavSection.models => const ModelsView(),
    };
  }
}
