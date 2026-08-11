import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/panel_visibility.dart';
import '../../agents/logic/agent_changes.dart';
import '../../files/logic/files_browser.dart';
import '../../files/presentation/files_panel_view.dart';
import '../../projects/logic/project.dart';
import '../../review/logic/diff_excerpt.dart';
import '../../review/logic/review_controller.dart';
import '../../review/presentation/review_surface.dart';
import '../../terminal/presentation/terminal_panel_view.dart';
import '../logic/active_workdir.dart';
import '../logic/bottom_panel.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/composer_file_request.dart';
import '../logic/composer_prefill.dart';
import '../logic/composer_snippet.dart';
import '../logic/panel_tabs.dart';
import '../logic/preview_panel.dart';

/// The one place a [PanelTab] becomes a widget.
///
/// Reaching across into other features' `presentation/` is the thing the
/// layering rule forbids everywhere else, and this is the same exemption
/// `shared/layouts/widgets/section_view.dart` takes for the shell: a mapping
/// table has to name both sides. Keeping it to one file is what stops the
/// exemption spreading — nothing else in `chat/` knows these classes exist.
///
/// [onClose] closes *this tab*. A surface asking to be dismissed doesn't know
/// it's in a tab, and shouldn't have to.
Widget panelFeatureView(
  PanelTab tab, {
  required PanelHost host,
  required VoidCallback onClose,
}) => switch (tab.feature) {
  PanelFeature.review => _ReviewTab(onClose: onClose, host: host),
  // Keyed by tab: two Terminal tabs are two live shells, and without a key
  // Flutter hands the second tab's id to the first one's element — same widget
  // type in the same slot — which leaves the new tab showing the old tab's
  // screen, or nothing at all.
  PanelFeature.terminal => _TerminalTab(
    key: ValueKey(tab.id),
    tabId: tab.id,
    host: host,
  ),
  PanelFeature.files => _FilesTab(tabId: tab.id, host: host),
};

/// A shell, in the folder the conversation is about.
///
/// The folder is the one the assistant works in — this chat's project, or the
/// default workspace when it belongs to none — so a command typed here acts on
/// the files being discussed. Keyed by the tab, and the shell dies with it.
class _TerminalTab extends ConsumerWidget {
  const _TerminalTab({super.key, required this.tabId, required this.host});

  final String tabId;

  /// Which panel this tab is in — only so the terminal can tell whether that
  /// panel is actually open.
  final PanelHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = switch (host) {
      PanelHost.preview => ref.watch(previewPanelOpenProvider),
      PanelHost.bottom => ref.watch(bottomPanelOpenProvider),
    };
    return TerminalPanelView(
      tabId: tabId,
      workdir: ref.watch(activeChatWorkdirProvider),
      // Both conditions, because both can hide a live terminal: a closed panel
      // stays in the tree so it can animate, and every open tab stays in the
      // tree so switching keeps its scrollback. A terminal that took the
      // keyboard in either case would swallow what the user typed at the chat.
      showing: panelOpen && PanelTabVisible.of(context),
      // A run of output picked out of the screen, as a quote on the next
      // message — the same gesture, the same menu and the same words the file
      // viewer answers a selection with. The whole terminal is a different
      // thing and asked for differently: drag its tab onto the conversation.
      //
      // Named for the tab it came from, since a terminal has no path to be
      // quoted from the way a file does.
      onAddToChat: (text) {
        final snippet = snippetOf(path: 'Terminal', text: text);
        if (snippet == null) return;
        ref.read(composerSnippetProvider.notifier).offer(snippet);
      },
    );
  }
}

/// The folder the open chat works in, browsable.
///
/// Same wiring as [_ReviewTab] and for the same reason: the panel sits beside
/// one conversation, so the folder it shows is that conversation's. Keyed by
/// the tab so two Files tabs are two places in the folder rather than one
/// selection shared between them.
///
/// The folder is [activeChatWorkdirProvider] — the same one the assistant is
/// given and the same one the header's browser opens — so a chat that belongs
/// to no project browses the app's workspace instead of showing an empty panel.
/// That was the whole complaint: the assistant saves its files there, and Files
/// was the one place that wouldn't show them.
class _FilesTab extends ConsumerWidget {
  const _FilesTab({required this.tabId, required this.host});

  final String tabId;

  /// Which panel this tab is in, so a second one opens beside it rather than in
  /// the other panel.
  final PanelHost host;

  /// Open [path] in a Files tab of its own.
  ///
  /// The tab is told what to show before it has drawn once: a feature's per-tab
  /// state is keyed by the id [PanelTabs.open] hands back, so the tab arrives
  /// already at the file with the folders above it open.
  void _openInNewTab(WidgetRef ref, String path, String root) {
    final id = ref
        .read(panelTabsProvider(host).notifier)
        .open(PanelFeature.files);
    ref.read(filesBrowserProvider(id).notifier).reveal(path: path, root: root);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = ref.watch(activeChatWorkdirProvider);

    // The tab is rooted at whichever folder the open chat works in, and
    // switching chats can move it to another one. Telling it so is what clears
    // the folders and the file it was showing out of the folder it just left.
    //
    // After the frame, never during it, and for the same reason as `_ReviewTab`
    // above: writing a provider while another is building is what Riverpod
    // forbids outright.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ref.read(filesBrowserProvider(tabId).notifier).showRoot(folder);
      }
    });

    return FilesPanelView(
      tabId: tabId,
      folder: folder,
      folderLabel: ref.watch(activeChatWorkdirLabelProvider),
      // Opening a second place in the folder is a *tab* operation, and Files
      // knows nothing about tabs — so the verb is wired here, in the one file
      // allowed to name both sides.
      onOpenInNewTab: (path) => _openInNewTab(ref, path, folder),
      // "Add to chat", off a file's right-click menu — the only way a file gets
      // onto a message from here. Reading one in the panel used to attach it on
      // its own, which read as the app doing things behind the user's back.
      onAddToChat: (path) =>
          ref.read(composerFileRequestProvider.notifier).add(path),
      onAddSelection: (path, text) {
        final snippet = snippetOf(path: path, text: text);
        if (snippet == null) return;
        ref.read(composerSnippetProvider.notifier).offer(snippet);
      },
    );
  }
}

/// What changed in the project the open chat belongs to.
///
/// The project comes from the conversation rather than a picker of its own: the
/// panel sits beside that chat, and a Review showing a different folder from
/// the one the assistant is working in would be the wrong changes on the same
/// screen.
///
/// The wiring lives here rather than in `features/review/` so Review stays
/// ignorant of chats, projects-as-the-chat-sees-them, and composers — it is
/// handed a folder and hands back a message.
class _ReviewTab extends ConsumerStatefulWidget {
  const _ReviewTab({required this.onClose, required this.host});

  final VoidCallback onClose;

  /// Which panel this tab sits in — how the surface knows whether anyone can
  /// actually see it, since a closed panel keeps its tabs in the tree.
  final PanelHost host;

  @override
  ConsumerState<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends ConsumerState<_ReviewTab> {
  /// Whether the last frame had this tab on screen.
  ///
  /// Starts true so opening Review doesn't read the repository twice — the
  /// provider's own first read is already on its way.
  bool _wasVisible = true;

  /// Read the repository again, if there is one on screen to read.
  void _lookAgain() {
    final folder = ref.read(projectByIdProvider(_projectId))?.path;
    if (folder == null) return;
    ref.read(reviewProvider(folder).notifier).refresh();
  }

  String? get _projectId => ref.read(chatSessionsProvider).openProjectId;

  @override
  Widget build(BuildContext context) {
    final projectId = ref.watch(
      chatSessionsProvider.select((s) => s.openProjectId),
    );
    final project = ref.watch(projectByIdProvider(projectId));
    // Keep Review's "Last turn" scope fed with what the assistant just changed
    // in this conversation — the same exemption as the import above, and for
    // the same reason: Review narrows a file list by these paths and must not
    // have to know an agent or a chat exists to get them.
    final lastTurn = ref.watch(lastTurnAgentPathsProvider);
    // After the frame, never during it: writing a provider while another is
    // building is what Riverpod forbids outright.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ref.read(reviewLastTurnPathsProvider.notifier).show(lastTurn);
      }
    });

    // On screen means *this tab* is the one showing and the panel holding it is
    // open — a closed panel keeps its tabs built, so the tab's own flag is only
    // half the answer.
    final visible =
        PanelTabVisible.of(context) &&
        ref.watch(switch (widget.host) {
          PanelHost.preview => previewPanelOpenProvider,
          PanelHost.bottom => bottomPanelOpenProvider,
        });

    // The assistant has finished a turn while Review was being watched. It may
    // have written files, staged them, or committed the lot — so the list on
    // screen is about a repository that has moved.
    //
    // At the *end* of the turn and not on each write: watching what the agent
    // touches meant six `git` calls every time it saved a file, which is the
    // storm [ReviewController.build] is written to avoid. A turn that ended is
    // one read.
    ref.listen(chatSessionsProvider.select((s) => s.sending), (was, now) {
      if (was == true && now == false && visible) _lookAgain();
    });

    // Coming back to the tab is the other moment the answer may be stale — a
    // turn that ended while it was hidden, or a `git commit` typed into the
    // Terminal tab next to it. Asked on arrival rather than polled, so a tab
    // nobody is looking at costs nothing.
    if (visible && !_wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) _lookAgain();
      });
    }
    _wasVisible = visible;

    final folder = project?.path;
    return ReviewSurface(
      project: project,
      onClose: widget.onClose,
      // Into the composer, not straight to the agent: which model answers is
      // chosen down there, and so is whether to send it at all.
      onAskAgent: (message) =>
          ref.read(composerPrefillProvider.notifier).offer(message),
      // The same two gestures the file viewer offers, in the same words: a
      // highlight goes as a quote of those lines, a file goes as the file. Both
      // are asked for — reading a diff attaches nothing on its own.
      //
      // Paths reach the composer absolute, because the folder Review counts
      // from is not something the chat knows.
      onAddSelection: folder == null
          ? null
          : (excerpt) => _addSelection(ref, folder, excerpt),
      onAddFile: folder == null
          ? null
          : (file) => ref
                .read(composerFileRequestProvider.notifier)
                .add('$folder/${file.path}'),
    );
  }

  /// The highlighted lines as a quote of the file they came out of, numbered
  /// where the diff could say which lines they were.
  void _addSelection(WidgetRef ref, String folder, DiffExcerpt excerpt) {
    final snippet = snippetOf(
      path: '$folder/${excerpt.path}',
      text: excerpt.text,
      startLine: excerpt.startLine,
      endLine: excerpt.endLine,
    );
    if (snippet == null) return;
    ref.read(composerSnippetProvider.notifier).offer(snippet);
  }
}
