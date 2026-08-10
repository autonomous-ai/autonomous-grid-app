import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/chat/logic/chat_sessions_controller.dart';
import '../../features/chat/logic/panel_tabs.dart';
import '../../features/command_palette/presentation/command_palette.dart';
import '../../features/git/logic/background_git_installer.dart';
import '../../features/node_setup/logic/background_agent_controller.dart';
import '../../features/node_setup/logic/background_model_controller.dart';
import '../../features/scheduled/logic/task_delivery.dart';
import '../../features/scheduled/logic/task_conversation_id.dart';
import '../../features/scheduled/logic/task_unread_store.dart';
import '../../infrastructure/platform/desktop_notifier.dart';
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
      // Opening the app does NOT put this computer back to work. Serving costs
      // the user's own GPU and battery, so it stays their decision, made on the
      // Engines tab — an app that quietly starts an engine on every launch is
      // spending their machine without asking. An engine that outlived the app
      // is still adopted, just not started: ProviderView reconciles when the
      // Engines tab opens, so what the screen says stays true either way.
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
      // Git is the one tool the assistants borrow rather than bring: pulling a
      // plugin from a repository shells out to it, and on Windows Hermes runs
      // every command through the shell that ships with it. Same treatment as
      // the assistants — adopt the user's own if they have one, quietly fetch
      // ours if they don't, and never make anyone wait for it.
      unawaited(ref.read(backgroundGitInstallerProvider).startIfNeeded());
      // Scheduled tasks run whether the app is open or not, and Hermes just
      // leaves the result in a file. Start looking for those results, so they
      // land in Chat instead of sitting somewhere the user never looks.
      ref.read(taskDeliveryProvider.notifier).start();
      // If the app opened straight onto a task's chat, it's already being read —
      // clear its "new results" badge (the listen below only fires on a change,
      // not on this first value).
      _markTaskChatRead(ref.read(chatSessionsProvider).activeId);
      // The launch update check lives here, not at startup: the shell is only
      // reached once first-run setup is done or skipped, so Sparkle's "restart
      // to update" prompt can't land on top of a model download.
      unawaited(ref.read(appUpdaterServiceProvider).checkInBackground());
      // The OS notification prompt, for the same two reasons: it must not land
      // during first-run setup, and asking for it in `main` held back the first
      // frame — the macOS dialog doesn't return until the user answers, so the
      // window sat black behind it. Here the app is drawn and the prompt makes
      // sense: the user is looking at the thing asking.
      unawaited(ref.read(desktopNotifierProvider).ensurePermission());
    });
  }

  /// Opening a scheduled task's chat is reading its result — clear that task's
  /// "new results" badge. A no-op for any other chat (or none open).
  void _markTaskChatRead(String? conversationId) {
    final jobId = jobIdOfTaskConversation(conversationId);
    if (jobId == null) return;
    ref.read(taskUnreadProvider.notifier).markRead(jobId);
  }

  @override
  Widget build(BuildContext context) {
    // Re-colour the whole shell the instant the theme flips. The shell and its
    // `const` children (the sidebar, the main body) read their colours from a
    // global the element tree can't track, so without an explicit dependency they
    // only repaint when some other change rebuilds them — the "click a row and
    // then it changes" symptom. Subscribing here rebuilds sidebar + pane together.
    AppTheme.watch(context);

    // Opening a task's chat clears its "new results" badge — the sidebar's dot
    // and the Scheduled list's pill both go quiet the moment it's read.
    ref.listen(
      chatSessionsProvider.select((s) => s.activeId),
      (_, id) => _markTaskChatRead(id),
    );

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
        // ⌃⇧G opens Review beside the chat — the key the preview panel's
        // launcher advertises, and Codex's own binding for the same thing.
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          control: true,
          shift: true,
        ): _openReview,
        // ⌘P opens the project's files beside the chat. Both modifiers, the way
        // ⌘K above does it: the launcher spells it the macOS way, but the key
        // has to work on the two platforms that call it Ctrl.
        //
        // The menu has advertised this since Files shipped and nothing was
        // listening — the `shortcut` on [PanelFeature] is a *label*, and a label
        // is a promise the app has to keep somewhere else.
        const SingleActivator(LogicalKeyboardKey.keyP, meta: true): _openFiles,
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            _openFiles,
        // ⌃` opens a terminal under the chat — the key every editor on all three
        // platforms uses for the panel below, so it needs no second binding for
        // Windows and Linux the way the ⌘ ones do.
        const SingleActivator(LogicalKeyboardKey.backquote, control: true):
            _openTerminal,
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

  /// Show what changed in the open chat's project, beside the conversation.
  ///
  /// Also brings the user back to Chat: the panel lives there, so firing this
  /// from Settings would open something they can't see.
  void _openReview() {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    // Reveal, not open: pressing the shortcut again should bring the Review
    // already on screen to the front rather than stack another one behind it.
    ref
        .read(panelTabsProvider(PanelHost.preview).notifier)
        .reveal(PanelFeature.review);
  }

  /// Browse the open chat's project, beside the conversation.
  ///
  /// Same two moves as [_openReview] and for the same two reasons: back to Chat,
  /// because that is where the panel lives, and reveal rather than open, because
  /// pressing a shortcut twice means "show me that" both times.
  void _openFiles() {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    ref
        .read(panelTabsProvider(PanelHost.preview).notifier)
        .reveal(PanelFeature.files);
  }

  /// A shell in the folder the conversation is about, under the conversation.
  ///
  /// The panel *below*, where the other two open beside — which is what ⌃`
  /// means everywhere else and is the right shape here too: Review and Files are
  /// read next to what you are asking about, while a terminal is watched under
  /// it, wide and short.
  void _openTerminal() {
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    ref
        .read(panelTabsProvider(PanelHost.bottom).notifier)
        .reveal(PanelFeature.terminal);
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
