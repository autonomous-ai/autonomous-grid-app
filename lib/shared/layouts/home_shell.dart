import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/chat/presentation/chat_pane.dart';
import '../../features/network/logic/create_network_controller.dart';
import '../../features/node_setup/logic/auto_host_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_surface.dart';
import 'widgets/ambient_background.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/grid_provision_banner.dart';
import 'widgets/session_expired_banner.dart';

/// The main app frame: a full-width title bar over one glass panel that holds
/// the whole app — chat, with its history rail and open conversation.
///
/// Setting this computer up is *not* its job any more: a machine that isn't
/// ready never reaches the shell — [RootView] shows the installer instead. So
/// everything here can assume a usable app. The grid, engine and guide screens
/// live in the account menu (each a dialog), not in a sidebar.
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

    // The starter grid is provisioned asynchronously, so on a first sign-in it
    // can arrive after the frame above — resume once it does.
    ref.listen(selectedNetworkProvider, (_, next) {
      if (next != null) _resumeSharing();
    });

    // A lit backdrop behind everything, then one floating glass panel over it
    // (macOS Tahoe-style) holding the whole app: chat, edge to edge. The grid,
    // engine and guide screens moved into the account menu (each a dialog), so
    // the window is just the conversation — history rail + the open chat.
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
                  child: GlassSurface(
                    borderRadius: BorderRadius.circular(20),
                    fill: AppGlass.panelFill,
                    boxShadow: AppGlass.shadow,
                    child: const ChatPane(),
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
