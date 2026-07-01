import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_update_controller.dart';
import '../../features/app_update/presentation/app_update_banner.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/debug/presentation/debug_view.dart';
import '../../features/network/presentation/networks_pane.dart';
import '../../features/node_setup/logic/node_capabilities.dart';
import '../../features/node_setup/logic/node_setup_controller.dart';
import '../../features/node_setup/logic/node_setup_plan.dart';
import '../../features/overlord/presentation/overlord_view.dart';
import '../../features/playground/presentation/playground_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../../shared/app_info.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_surface.dart';
import 'shell_state.dart';
import 'widgets/ambient_background.dart';
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
    _autoCheckAppUpdate(ref);

    // A lit backdrop behind everything, then floating glass panels over it
    // (macOS Tahoe-style): a translucent sidebar and a near-opaque content
    // panel that both lift off the wallpaper with a margin and a shadow.
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Stack(
        children: [
          const Positioned.fill(child: AmbientBackground()),
          Column(
            children: [
              const AppTopBar(),
              const SessionExpiredBanner(),
              const AppUpdateBanner(),
              const NodeSetupBanner(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SideNav(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GlassSurface(
                          borderRadius: BorderRadius.circular(20),
                          fill: AppGlass.panelFill,
                          boxShadow: AppGlass.shadow,
                          child: _Content(section: section),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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

  /// Run a one-shot version check in the background once the app version is
  /// known. Listening (rather than reading in build) keeps the mutation out of
  /// the build phase; `autoCheck` guards against running more than once.
  void _autoCheckAppUpdate(WidgetRef ref) {
    ref.listen(appVersionProvider, (_, next) {
      if (next.asData?.value == null) return;
      ref.read(appUpdateControllerProvider.notifier).autoCheck();
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
      NavSection.debug => const DebugView(),
    };
  }
}
