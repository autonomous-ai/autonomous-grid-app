import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/chat/presentation/chat_pane.dart';
import '../../features/network/logic/create_network_controller.dart';
import '../../features/network/presentation/how_to_use_view.dart';
import '../../features/network/presentation/networks_pane.dart';
import '../../features/node_setup/logic/auto_host_controller.dart';
import '../../features/plugins/presentation/plugins_view.dart';
import '../../features/projects/presentation/projects_view.dart';
import '../../features/provider_node/presentation/provider_view.dart';
import '../../features/scheduled/logic/task_delivery.dart';
import '../../features/scheduled/presentation/scheduled_view.dart';
import '../theme/app_theme.dart';
import 'shell_state.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/grid_provision_banner.dart';
import 'widgets/session_expired_banner.dart';

/// The main app frame: the sidebar on the left, the open section on the right.
///
/// Setting this computer up is *not* its job any more: a machine that isn't ready
/// never reaches the shell — [RootView] shows the installer instead. So everything
/// here can assume a usable app.
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
      // A user who never went through the installer (they skipped it, or they're
      // a guest on someone else's grid) can still reach the shell owning no
      // grid. No-ops once they own one.
      ref
          .read(createNetworkControllerProvider.notifier)
          .createFirstGridIfNeeded();
      _resumeSharing();
      // Scheduled tasks run whether the app is open or not, and Hermes just
      // leaves the result in a file. Start looking for those results, so they
      // land in Chat instead of sitting somewhere the user never looks.
      ref.read(taskDeliveryProvider.notifier).start();
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
  /// still-running engine rather than starting a second one, and it runs once per
  /// session — so a user who deliberately stopped their engine doesn't get it
  /// restarted behind their back.
  void _resumeSharing() =>
      ref.read(autoHostControllerProvider.notifier).startIfReady();

  @override
  Widget build(BuildContext context) {
    // The starter grid is provisioned asynchronously, so on a first sign-in it
    // can arrive after the frame above — resume once it does.
    ref.listen(selectedNetworkProvider, (_, next) {
      if (next != null) _resumeSharing();
    });

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AppSidebar(),
              Expanded(
                child: Column(
                  children: [
                    const AppTopBar(),
                    const SessionExpiredBanner(),
                    const GridProvisionBanner(),
                    const Expanded(child: _SectionView()),
                  ],
                ),
              ),
            ],
          ),
          const _SidebarCastShadow(),
        ],
      ),
    );
  }
}

class _SidebarCastShadow extends StatelessWidget {
  const _SidebarCastShadow();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: AppSidebar.width - 1,
      top: 0,
      bottom: 0,
      width: 14,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0x12000000),
                Color(0x07000000),
                Colors.transparent,
              ],
              stops: [0, 0.42, 1],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pane the sidebar drives — chat, or one of the three screens behind it.
class _SectionView extends ConsumerWidget {
  const _SectionView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(shellSectionProvider)) {
      ShellSection.chat => const ChatPane(),
      ShellSection.scheduled => const ScheduledView(),
      ShellSection.plugins => const PluginsView(),
      ShellSection.projects => const ProjectsView(),
      ShellSection.grids => const NetworksPane(),
      ShellSection.engines => const ProviderView(),
      ShellSection.guide => const HowToUseView(),
    };
  }
}
