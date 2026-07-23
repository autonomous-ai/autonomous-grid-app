import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/command_palette/presentation/command_palette.dart';
import '../../features/node_setup/logic/auto_host_controller.dart';
import '../../features/node_setup/logic/background_agent_controller.dart';
import '../../features/node_setup/logic/background_model_controller.dart';
import '../../features/scheduled/logic/task_delivery.dart';
import '../theme/app_theme.dart';
import 'settings_pane.dart';
import 'shell_state.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/section_view.dart';
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
      _resumeSharing();
      // The heavy model download isn't part of first-run setup any more: kick it
      // off in the background so the user can chat while it lands, with its
      // progress in the top bar. No-ops when there's nothing to download.
      unawaited(
        ref.read(backgroundModelControllerProvider.notifier).startIfNeeded(),
      );
      // Same idea for the assistants: a computer set up before an agent joined
      // the catalog never sees the first-run installer again, so top it up here
      // rather than leaving a row the user can only look at.
      unawaited(ref.read(backgroundAgentInstallerProvider).startIfNeeded());
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
    // Re-colour the whole shell the instant the theme flips. The shell and its
    // `const` children (the sidebar, the main body) read their colours from a
    // global the element tree can't track, so without an explicit dependency they
    // only repaint when some other change rebuilds them — the "click a row and
    // then it changes" symptom. Subscribing here rebuilds sidebar + pane together.
    AppTheme.watch(context);

    // The user's grid is synced from the server after sign-in, so it can land
    // after the frame above — resume sharing once one does.
    ref.listen(selectedNetworkProvider, (_, next) {
      if (next != null) _resumeSharing();
    });

    final section = ref.watch(shellSectionProvider);

    // ⌘K from anywhere — the palette is how you find a chat, a project or a task
    // without knowing which screen the app keeps it on.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openPalette,
        // ⌘, opens Settings — the macOS convention, so muscle memory works.
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppPalette.windowBg,
          // The setup screens live together in Settings, which takes the window
          // — the sidebar is for the work you came to do, not the plumbing.
          body: section.isSettings
              ? SettingsPane(section: section)
              : const _MainShellBody(),
        ),
      ),
    );
  }

  void _openPalette() => showCommandPalette(context);

  void _openSettings() {
    ref.read(shellSectionProvider.notifier).select(kDefaultSettingsSection);
  }
}

class _MainShellBody extends StatelessWidget {
  const _MainShellBody();

  @override
  Widget build(BuildContext context) {
    // No cast shadow between the rail and the pane — the sidebar's own right
    // hairline is the separator, the way Codex draws it. Flat and clean.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSidebar(),
        Expanded(
          child: Column(
            children: [
              const AppTopBar(),
              const SessionExpiredBanner(),
              const Expanded(child: _SectionView()),
            ],
          ),
        ),
      ],
    );
  }
}

/// The pane the sidebar drives — chat, or one of the screens behind it.
class _SectionView extends ConsumerWidget {
  const _SectionView();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      SectionView(section: ref.watch(shellSectionProvider));
}
