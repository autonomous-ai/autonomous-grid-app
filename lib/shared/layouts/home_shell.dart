import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/chat/presentation/chat_pane.dart';
import '../../features/network/logic/create_network_controller.dart';
import '../../features/node_setup/logic/auto_host_controller.dart';
import '../../features/debug/presentation/debug_view.dart';
import '../../features/network/presentation/how_to_use_view.dart';
import '../../features/network/presentation/networks_pane.dart';
import '../../features/overlord/presentation/overlord_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_surface.dart';
import 'shell_state.dart';
import 'widgets/ambient_background.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/grid_provision_banner.dart';
import 'widgets/session_expired_banner.dart';
import 'widgets/side_nav.dart';

/// The main app frame, Tailscale-style: a full-width title bar on top, a left
/// nav sidebar, and the active section to its right.
///
/// Setting this computer up is *not* its job any more: a machine that isn't
/// ready never reaches the shell — [RootView] shows the installer instead. So
/// everything here can assume a usable app.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    // Post-frame so we never mutate state during the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A user who never went through the installer (they skipped it, or
      // they're a guest on someone else's grid) can still reach the shell
      // owning no grid. No-ops once they own one.
      ref
          .read(createNetworkControllerProvider.notifier)
          .createFirstGridIfNeeded();
      _resumeSharing();
      // The launch update check lives here, not at startup: the shell is only
      // reached once first-run setup is done or skipped, so Sparkle's "restart
      // to update" prompt can't land on top of a model download.
      unawaited(ref.read(appUpdaterServiceProvider).checkInBackground());
    });
  }

  /// Put this computer back on its grid when it isn't serving — after a reboot,
  /// say, where the engine died with the machine.
  ///
  /// Without this, an already-set-up computer would sail past the installer
  /// (nothing left to install) into an app whose grid has no model on it, and
  /// chat would answer nothing. It only ever *resumes*: the controller adopts a
  /// still-running engine rather than starting a second one, and it runs once
  /// per session — so a user who deliberately stopped their engine doesn't get
  /// it restarted behind their back.
  void _resumeSharing() =>
      ref.read(autoHostControllerProvider.notifier).startIfReady();

  @override
  Widget build(BuildContext context) {
    final section = ref.watch(navSectionProvider);

    // The starter grid is provisioned asynchronously, so on a first sign-in it
    // can arrive after the frame above — resume once it does.
    ref.listen(selectedNetworkProvider, (_, next) {
      if (next != null) _resumeSharing();
    });

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
              const GridProvisionBanner(),
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

}

/// Routes the active nav section to its pane. Networks is a two-column
/// list/detail; the rest render their existing single view. Every section is
/// reachable on any grid — Engines gates the sharing step inside itself rather
/// than disappearing from the sidebar.
class _Content extends ConsumerWidget {
  const _Content({required this.section});
  final NavSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (section) {
      NavSection.networks => const NetworksPane(),
      NavSection.chat => const ChatPane(),
      NavSection.overlord => const OverlordView(),
      NavSection.howToUse => const HowToUseView(),
      NavSection.provider => const ProviderView(),
      NavSection.debug => const DebugView(),
    };
  }
}
