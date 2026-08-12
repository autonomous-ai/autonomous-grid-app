import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/panels/panel_tabs.dart';
import '../../../../shared/widgets/panel_visibility.dart';
import '../../../files/logic/files_browser.dart';
import '../../../files/presentation/files_panel_view.dart';
import '../../../projects/logic/project.dart';
import '../../../review/logic/review_controller.dart';
import '../../../review/presentation/review_surface.dart';
import '../../../terminal/presentation/terminal_panel_view.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/project_flow.dart';

/// The one place a [PanelTab] beside a Code project becomes a widget — the
/// project's twin of the chat's `panelFeatureView`.
///
/// Same surfaces, same tabs, same panel; what differs is only what they are
/// rooted at. Here it is the project's copy on this computer, at
/// `~/.grid/app/code/<project>`, which the flow keeps current.
///
/// The chat's own panels are woven into its composer — "add to chat", snippets —
/// none of which a task-driven project has, so those hooks are left off. What
/// Review does offer, "ask about this", goes to the task box below through
/// [codeComposerPrefillProvider], the one thing that maps cleanly.
///
/// Reaching across into other features' `presentation/` is the exemption the
/// chat's mapping table takes for the same reason: a table that maps panels onto
/// features has to name both sides.
Widget codePanelFeatureView(
  PanelTab tab, {
  required VoidCallback onClose,
  required String projectId,
  required String projectName,
  required String clonePath,
}) => switch (tab.feature) {
  PanelFeature.review => _ReviewTab(
    onClose: onClose,
    projectId: projectId,
    projectName: projectName,
    clonePath: clonePath,
  ),
  // Keyed by tab: two Terminal tabs are two live shells, and without a key
  // Flutter hands the second tab's id to the first one's element — same widget
  // type in the same slot — which leaves the new tab showing the old tab's
  // screen, or nothing at all.
  PanelFeature.terminal => _TerminalTab(
    key: ValueKey(tab.id),
    tabId: tab.id,
    clonePath: clonePath,
  ),
  PanelFeature.files => _FilesTab(
    tabId: tab.id,
    projectName: projectName,
    clonePath: clonePath,
  ),
};

/// A shell in the project's copy, so a command typed here acts on the code the
/// tasks are changing. Keyed by the tab, and the shell dies with it.
class _TerminalTab extends ConsumerWidget {
  const _TerminalTab({super.key, required this.tabId, required this.clonePath});

  final String tabId;
  final String clonePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TerminalPanelView(
    tabId: tabId,
    workdir: clonePath,
    // Both conditions, because both can hide a live terminal: a closed panel
    // stays in the tree so it can animate, and every open tab stays in the tree
    // so switching keeps its scrollback.
    showing:
        ref.watch(panelOpenProvider(PanelHost.code)) &&
        PanelTabVisible.of(context),
    // Nothing to quote a run of output *into*: a task is a request typed into
    // the box below, not a conversation this screen can add a block to.
    onAddToChat: null,
  );
}

/// The project's copy, browsable. Keyed by the tab so two Files tabs are two
/// places in the folder rather than one selection shared between them.
class _FilesTab extends ConsumerWidget {
  const _FilesTab({
    required this.tabId,
    required this.projectName,
    required this.clonePath,
  });

  final String tabId;
  final String projectName;
  final String clonePath;

  /// Open [path] in a Files tab of its own.
  ///
  /// The tab is told what to show before it has drawn once: a feature's per-tab
  /// state is keyed by the id [PanelTabs.open] hands back, so the tab arrives
  /// already at the file with the folders above it open.
  void _openInNewTab(WidgetRef ref, String path) {
    final id = ref
        .read(panelTabsProvider(PanelHost.code).notifier)
        .open(PanelFeature.files);
    ref
        .read(filesBrowserProvider(id).notifier)
        .reveal(path: path, root: clonePath);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The tab is rooted at the open project's copy, and switching projects moves
    // it to another one. Telling it so is what clears the folders and the file
    // it was showing out of the folder it just left.
    //
    // After the frame, never during it: writing a provider while another is
    // building is what Riverpod forbids outright.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ref.read(filesBrowserProvider(tabId).notifier).showRoot(clonePath);
      }
    });

    return FilesPanelView(
      tabId: tabId,
      folder: clonePath,
      folderLabel: projectName,
      // Opening a second place in the folder is a *tab* operation, and Files
      // knows nothing about tabs — so the verb is wired here.
      onOpenInNewTab: (path) => _openInNewTab(ref, path),
      // No conversation to put a file or a quote on: the box below asks for a
      // task, and a task is a sentence, not an attachment.
      onAddToChat: null,
      onAddSelection: null,
    );
  }
}

/// What has changed in the project's copy since the team's trunk.
class _ReviewTab extends ConsumerStatefulWidget {
  const _ReviewTab({
    required this.onClose,
    required this.projectId,
    required this.projectName,
    required this.clonePath,
  });

  final VoidCallback onClose;
  final String projectId;
  final String projectName;
  final String clonePath;

  @override
  ConsumerState<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends ConsumerState<_ReviewTab> {
  /// Whether the last frame had this tab on screen.
  ///
  /// Starts true so opening Review doesn't read the repository twice — the
  /// provider's own first read is already on its way.
  bool _wasVisible = true;

  /// Read the repository again — the folder on screen has moved.
  void _lookAgain() {
    ref.read(reviewProvider(widget.clonePath).notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    // On screen means *this tab* is the one showing and the panel holding it is
    // open — a closed panel keeps its tabs built, so the tab's own flag is only
    // half the answer.
    final visible =
        PanelTabVisible.of(context) &&
        ref.watch(panelOpenProvider(PanelHost.code));

    // A task of this member's has finished being published, and the flow
    // re-clones the copy on this computer as the last step of that — so every
    // file this diff was counted from has just been written again underneath
    // it. The chat's Review re-reads at the end of a turn for exactly this
    // reason; a project's turn ends here.
    ref.listen(
      projectFlowProvider(widget.projectId).select((s) => s.isPublishing),
      (was, now) {
        if (was == true && now == false && visible) _lookAgain();
      },
    );

    // Coming back to the tab is the other moment the answer may be stale: a
    // task that landed while it was hidden, or a `git` typed into the Terminal
    // tab beside it. Asked on arrival rather than polled, so a tab nobody is
    // looking at costs nothing.
    if (visible && !_wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        _lookAgain();
      });
    }
    _wasVisible = visible;

    return ReviewSurface(
      project: Project(
        id: widget.projectId,
        name: widget.projectName,
        path: widget.clonePath,
      ),
      onClose: widget.onClose,
      // The one hook a task project has: a request goes to the box below, where
      // the grid picks who runs it, rather than off on its own.
      onAskAgent: (message) =>
          ref.read(codeComposerPrefillProvider.notifier).offer(message),
      onAddSelection: null,
      onAddFile: null,
    );
  }
}
