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
  PanelFeature.review => _ReviewTab(onClose: onClose),
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
    );
  }
}

/// The open chat's project folder, browsable.
///
/// Same wiring as [_ReviewTab] and for the same reason: the panel sits beside
/// one conversation, so the folder it shows is that conversation's. Keyed by
/// the tab so two Files tabs are two places in the project rather than one
/// selection shared between them.
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
    final projectId = ref.watch(
      chatSessionsProvider.select((s) => s.openProjectId),
    );
    final folder = ref.watch(projectByIdProvider(projectId))?.path;

    return FilesPanelView(
      tabId: tabId,
      folder: folder,
      // Opening a second place in the project is a *tab* operation, and Files
      // knows nothing about tabs — so the verb is wired here, in the one file
      // allowed to name both sides.
      onOpenInNewTab: folder == null
          ? null
          : (path) => _openInNewTab(ref, path, folder),
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
class _ReviewTab extends ConsumerWidget {
  const _ReviewTab({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final folder = project?.path;
    return ReviewSurface(
      project: project,
      onClose: onClose,
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
