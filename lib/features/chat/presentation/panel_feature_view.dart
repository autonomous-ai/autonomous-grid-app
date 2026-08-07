import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_changes.dart';
import '../../browser/presentation/browser_panel_view.dart';
import '../../files/logic/files_browser.dart';
import '../../files/presentation/files_panel_view.dart';
import '../../projects/logic/project.dart';
import '../../review/logic/review_controller.dart';
import '../../review/presentation/review_surface.dart';
import '../../side_chat/presentation/side_chat_panel_view.dart';
import '../../terminal/presentation/terminal_panel_view.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/composer_prefill.dart';
import '../logic/panel_tabs.dart';

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
Widget panelFeatureView(PanelTab tab, {required VoidCallback onClose}) =>
    switch (tab.feature) {
      PanelFeature.review => _ReviewTab(onClose: onClose),
      PanelFeature.terminal => const TerminalPanelView(),
      PanelFeature.browser => const BrowserPanelView(),
      PanelFeature.files => _FilesTab(tabId: tab.id),
      PanelFeature.sideChat => const SideChatPanelView(),
    };

/// The open chat's project folder, browsable.
///
/// Same wiring as [_ReviewTab] and for the same reason: the panel sits beside
/// one conversation, so the folder it shows is that conversation's. Keyed by
/// the tab so two Files tabs are two places in the project rather than one
/// selection shared between them.
class _FilesTab extends ConsumerWidget {
  const _FilesTab({required this.tabId});

  final String tabId;

  /// Open [path] in a Files tab of its own.
  ///
  /// The tab is told what to show before it has drawn once: a feature's per-tab
  /// state is keyed by the id [PanelTabs.open] hands back, so the tab arrives
  /// already at the file with the folders above it open.
  void _openInNewTab(WidgetRef ref, String path, String root) {
    final id = ref.read(panelTabsProvider.notifier).open(PanelFeature.files);
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

    return ReviewSurface(
      project: ref.watch(projectByIdProvider(projectId)),
      onClose: onClose,
      // Into the composer, not straight to the agent: which model answers is
      // chosen down there, and so is whether to send it at all.
      onAskAgent: (message) =>
          ref.read(composerPrefillProvider.notifier).offer(message),
    );
  }
}
