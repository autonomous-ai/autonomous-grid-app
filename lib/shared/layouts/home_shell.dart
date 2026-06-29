import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/debug/presentation/debug_view.dart';
import '../../features/models/presentation/models_view.dart';
import '../../features/network/presentation/networks_pane.dart';
import '../../features/node_setup/logic/node_capabilities.dart';
import '../../features/node_setup/logic/node_setup_controller.dart';
import '../../features/node_setup/logic/node_setup_plan.dart';
import '../../features/overlord/presentation/overlord_view.dart';
import '../../features/playground/presentation/playground_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../theme/app_theme.dart';
import 'shell_state.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/node_setup_banner.dart';
import 'widgets/session_expired_banner.dart';
import 'widgets/side_nav.dart';

/// The main app frame, Tailscale-style: a full-width title bar on top, a left
/// nav sidebar, and the active section to its right. Also kicks off the
/// hands-off node setup in the background and surfaces it via [NodeSetupBanner].
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(navSectionProvider);
    _autoStartNodeSetup(ref);

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Column(
        children: [
          const AppTopBar(),
          const Divider(height: 1),
          const SessionExpiredBanner(),
          const NodeSetupBanner(),
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

  /// Once capabilities are known, start filling the gaps in the background — no
  /// prompt. Only on provider-capable hosts (macOS / Linux); Windows is
  /// consumer-only, so there's nothing to install there.
  void _autoStartNodeSetup(WidgetRef ref) {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    ref.listen(nodeCapabilitiesProvider, (_, next) {
      final caps = next.asData?.value;
      if (caps == null) return;
      ref
          .read(nodeSetupControllerProvider.notifier)
          .autoStart(buildSetupPlan(caps));
    });
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
      NavSection.overlord => const OverlordView(),
      NavSection.playground => const PlaygroundView(),
      NavSection.provider => const ProviderView(),
      NavSection.models => const ModelsView(),
      NavSection.debug => const DebugView(),
    };
  }
}
