import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/logic/app_updater_service.dart';
import '../../features/app_update/logic/update_watcher.dart';
import '../../features/chat/logic/chat_sessions_controller.dart';
import '../../features/code/logic/code_projects_controller.dart';
import '../../features/code/presentation/code_pane.dart';
import '../../features/command_palette/presentation/command_palette.dart';
import '../../features/git/logic/background_git_installer.dart';
import '../../features/node_setup/logic/background_agent_controller.dart';
import '../../features/node_setup/logic/background_model_controller.dart';
import '../../features/provider_node/logic/auto_serve_controller.dart';
import '../../features/scheduled/logic/task_delivery.dart';
import '../../features/scheduled/logic/task_conversation_id.dart';
import '../../features/scheduled/logic/task_unread_store.dart';
import '../../infrastructure/platform/desktop_notifier.dart';
import '../panels/panel_tabs.dart';
import '../theme/app_theme.dart';
import 'settings_pane.dart';
import 'reveal_chat.dart';
import 'shell_state.dart';
import 'widgets/app_status_rail.dart';
import 'widgets/app_top_bar.dart';
import 'widgets/section_view.dart';
import 'widgets/session_expired_banner.dart';
import 'widgets/sidebar_fold.dart';

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
      // Opening the app does NOT put this computer back to work by itself.
      // Serving costs the user's own GPU and battery, so it stays their
      // decision — an app that quietly starts an engine on every launch is
      // spending their machine without asking. An engine that outlived the app
      // is still adopted, just not started: ProviderView reconciles when the
      // Engines tab opens, so what the screen says stays true either way.
      //
      // The one exception is the box in the engine block that says "start this
      // when Grid opens", off until ticked: that tick *is* the decision, for
      // one named model on one named grid. Everything else about it stays
      // timid — see [AutoServeStarter].
      unawaited(ref.read(autoServeStarterProvider).startIfEnabled());
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
      // And if the history was already read before this shell was built, the
      // listener in `build` has no change left to fire on — so settle the
      // restored chat here too. Same reason as the line above.
      if (!ref.read(chatSessionsProvider).loading) settleRestoredChat(ref);
      // The launch update check lives here, not at startup: the shell is only
      // reached once first-run setup is done or skipped, so Sparkle's "restart
      // to update" prompt can't land on top of a model download.
      unawaited(ref.read(appUpdaterServiceProvider).checkInBackground());
      // The app's own half-hourly lane, started in the same breath and for the
      // same reason. It draws the sidebar banner; Sparkle's lane above keeps
      // running untouched, so a fault in this one still leaves the user a way
      // to hear about a release.
      ref.read(updateWatcherProvider.notifier).start();
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

    // The history has landed and the app has picked the chat to reopen on. If
    // that chat belongs to a document, this is where it gets its document —
    // see [settleRestoredChat]. Watched on `loading` rather than on the id, so
    // it fires once on the way in and never again.
    ref.listen(chatSessionsProvider.select((s) => s.loading), (was, now) {
      if (was != true || now) return;
      settleRestoredChat(ref);
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
        // ⌃⇧G opens Review beside the chat — the key the preview panel's
        // launcher advertises, and Codex's own binding for the same thing.
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          control: true,
          shift: true,
        ): _openReview,
        // ⌘P opens the chat's folder beside it. Both modifiers, the way
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
        // ⌘\ folds the sidebar away and back — the binding the toggle's own
        // tooltip advertises, and the one editors on all three platforms use
        // for exactly this.
        const SingleActivator(LogicalKeyboardKey.backslash, meta: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.backslash, control: true):
            _toggleSidebar,
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

  void _toggleSidebar() => ref.read(sidebarCollapsedProvider.notifier).toggle();

  void _openSettings() {
    ref.read(shellSectionProvider.notifier).select(kDefaultSettingsSection);
  }

  /// Show what changed in the project on screen, beside the conversation.
  ///
  /// Whose conversation depends on which half of the app is open — see
  /// [_revealBeside].
  void _openReview() => _revealBeside(PanelFeature.review);

  /// Browse the folder the conversation works in, beside it.
  void _openFiles() => _revealBeside(PanelFeature.files);

  /// A shell in the folder the conversation is about.
  ///
  /// In Home that is the panel *below*, where the other two open beside — which
  /// is what ⌃` means everywhere else and is the right shape here too: Review
  /// and Files are read next to what you are asking about, while a terminal is
  /// watched under it, wide and short. Code has no panel below, so its terminal
  /// opens in the one panel it does have.
  void _openTerminal() {
    if (ref.read(shellModeProvider) != ShellMode.code) {
      _reveal(PanelHost.bottom, PanelFeature.terminal);
      return;
    }
    _revealBeside(PanelFeature.terminal);
  }

  /// Open [feature] in whichever panel sits beside the conversation the user is
  /// actually looking at: the chat's, or a Code project's.
  ///
  /// The keys are labels on the launcher rows of *both* panels, so they have to
  /// answer in both halves — pointed at Chat unconditionally, ⌃⇧G in Code threw
  /// the user out of the project they were reading to show a diff of something
  /// else.
  void _revealBeside(PanelFeature feature) {
    if (ref.read(shellModeProvider) == ShellMode.code) {
      // Nothing to open it beside: Code with no project open is a list, and a
      // panel opened onto that is a tab waiting behind a screen the user cannot
      // see it from.
      if (ref.read(codeProjectIsOpenProvider)) _reveal(PanelHost.code, feature);
      return;
    }
    // Back to Chat first: the panel lives there, so firing this from Settings
    // would open something the user can't see.
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
    _reveal(PanelHost.preview, feature);
  }

  /// Reveal, not open: pressing the shortcut again should bring the tab already
  /// on screen to the front rather than stack another one behind it.
  void _reveal(PanelHost host, PanelFeature feature) =>
      ref.read(panelTabsProvider(host).notifier).reveal(feature);
}

class _MainShellBody extends StatelessWidget {
  const _MainShellBody();

  @override
  Widget build(BuildContext context) {
    // Collapsing narrows the rail, it never drops it — [SidebarFold] owns both
    // widths and the animation between them, and watches the collapsed flag
    // itself. That is why this widget reads no provider at all any more: the
    // fold has to rebuild 60 times a second while it runs, and it must not drag
    // the pane's whole subtree through those rebuilds with it.
    //
    // No cast shadow between the rail and the pane — the rail's own right
    // hairline is the separator, the way Codex draws it. Flat and clean.
    // A column around the row, not a row inside a column: the status rail runs
    // under the sidebar as well as the pane, so the window's bottom edge is one
    // unbroken line. Nested the other way the rail would start at x=284 and put
    // a step in that edge.
    // Selection belongs to what the app is *showing*, not to what it is steered
    // by. The rail, the top bar and the status strip are navigation: their words
    // are labels on things you press, and a drag across the page should pass
    // over them the way it passes over a toolbar in any other app.
    //
    // Drawn here rather than inside each control, because "is this a button?"
    // has one answer per *region* and a dozen per widget — the nav rows, the
    // fold toggle, the grid pill and both top-bar calls to action would each
    // have needed the same wrapper, and the next one added would have been
    // forgotten. What the shell frames ([_SectionView], and the banner, which
    // carries a message worth keeping) stays selectable.
    //
    // The cost is a sidebar chat title, which is a real string somebody might
    // want and is now behind a row that refuses. The chat's own header repeats
    // it inside the pane, where it can still be taken.
    //
    // **[AppStatusRail] is deliberately left out**, though it is chrome by every
    // other measure. Its figures open [GridStatPanel] through an `OverlayPortal`,
    // and an overlay child of one of those still inherits from where it sits in
    // the *widget* tree — so disabling the rail would reach into the members
    // panel and take the email addresses with it. Those are the most copyable
    // strings the app has.
    return const Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectionContainer.disabled(child: SidebarFold()),
              Expanded(
                child: Column(
                  children: [
                    SelectionContainer.disabled(child: AppTopBar()),
                    SessionExpiredBanner(),
                    Expanded(child: _SectionView()),
                  ],
                ),
              ),
            ],
          ),
        ),
        AppStatusRail(),
      ],
    );
  }
}

/// The pane the sidebar drives.
///
/// Which half of the app is open decides this before the section does: Code is
/// its own screen with its own rail, not one more entry in the nav, so it
/// replaces the pane wholesale rather than appearing inside it.
class _SectionView extends ConsumerWidget {
  const _SectionView();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(shellModeProvider)) {
        ShellMode.home => SectionView(section: ref.watch(shellSectionProvider)),
        ShellMode.code => const CodePane(),
      };
}
