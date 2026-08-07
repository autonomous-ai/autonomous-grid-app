import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/external_launch.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/panel_body.dart';
import '../../../shared/widgets/toast.dart';
import '../../projects/logic/agent_workspace.dart';
import '../logic/file_kind.dart';
import '../logic/file_preview.dart';
import '../logic/files_browser.dart';
import '../logic/files_path.dart';
import 'widgets/file_viewer.dart';
import 'widgets/files_breadcrumb.dart';
import 'widgets/files_tree.dart';

/// The project's files, in a preview-panel tab: a tree to pick from, the file
/// you picked, and the path between them.
///
/// Read-only on purpose. Editing beside a conversation is a second editor with
/// none of the first one's habits — undo, find, a language server — so this
/// shows the file and hands it to the real editor when the user wants more.
class FilesPanelView extends ConsumerWidget {
  const FilesPanelView({super.key, required this.tabId, required this.folder});

  final String tabId;

  /// The project folder this tab is rooted at, or null when the open chat
  /// belongs to no project.
  final String? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = this.folder;
    if (folder == null) return const _NoProject();

    final selected = ref.watch(
      filesBrowserProvider(tabId).select((s) => s.selected),
    );
    final showSource = ref.watch(
      filesBrowserProvider(tabId).select((s) => s.showSource),
    );
    final showTree = ref.watch(
      filesBrowserProvider(tabId).select((s) => s.showTree),
    );
    return PanelBody(
      toolbar: _Toolbar(
        tabId: tabId,
        folder: folder,
        selected: selected,
        showSource: showSource,
        showTree: showTree,
      ),
      main: FileViewer(path: selected, showSource: showSource),
      sideOpen: showTree,
      side: FilesTree(
        tabId: tabId,
        root: folder,
        onOpen: (entry) =>
            ref.read(filesBrowserProvider(tabId).notifier).select(entry.path),
      ),
    );
  }
}

/// Region 2: where you are, and the two ways out of here into the system.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.tabId,
    required this.folder,
    required this.selected,
    required this.showSource,
    required this.showTree,
  });

  final String tabId;
  final String folder;
  final String? selected;
  final bool showSource;
  final bool showTree;

  Future<void> _reveal(BuildContext context, WidgetRef ref) async {
    // Reveals the file's own folder when one is open, so the user lands on the
    // file rather than at the top of the project.
    final ok = await ref
        .read(hostShellServiceProvider)
        .openFolder(_parentOf(selected) ?? folder);
    if (ok || !context.mounted) return;
    ToastScope.show(
      context,
      const ToastSpec(
        message: "Couldn't open the folder.",
        severity: ToastSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final selected = this.selected;
    return Padding(
      // The same inset Review's toolbar takes, so the row under the tabs starts
      // in the same place whichever tab you switch to.
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: FilesBreadcrumb(
              crumbs: filePathCrumbs(root: folder, filePath: selected),
              filePath: selected,
            ),
          ),
          const SizedBox(width: 8),
          // Not offered until a file is open, and for the same reason the tree
          // exists: with nothing to read beside it, hiding the tree hides the
          // whole panel — and the empty state left behind would be telling you
          // to pick from a tree that isn't there.
          if (selected != null) ...[
            AppIconButton(
              icon: showTree
                  ? LucideIcons.panelRightClose300
                  : LucideIcons.panelRightOpen300,
              size: 15,
              tooltip: showTree ? 'Hide the file tree' : 'Show the file tree',
              onPressed: ref
                  .read(filesBrowserProvider(tabId).notifier)
                  .toggleTree,
            ),
            const SizedBox(width: 2),
          ],
          // Only Markdown has two ways to be read, so the switch between them is
          // only offered where it means something.
          if (selected != null && isMarkdownPath(selected)) ...[
            AppIconButton(
              icon: showSource ? LucideIcons.bookOpen300 : LucideIcons.code300,
              size: 15,
              // The tooltip names what the click *does*, not what is on screen:
              // a one-button switch whose icon flips is otherwise a guess.
              tooltip: showSource
                  ? 'Show it as a document'
                  : 'Show the Markdown source',
              onPressed: ref
                  .read(filesBrowserProvider(tabId).notifier)
                  .toggleSource,
            ),
            const SizedBox(width: 2),
          ],
          AppIconButton(
            icon: LucideIcons.refreshCw300,
            size: 14,
            tooltip: 'Re-read this folder',
            // The assistant writes in here while the panel is open, so the tree
            // and the open file both go stale on their own. One invalidate
            // covers every folder listing loaded and every file read.
            onPressed: () {
              ref.invalidate(workdirEntriesProvider);
              ref.invalidate(filePreviewProvider);
            },
          ),
          const SizedBox(width: 2),
          AppIconButton(
            icon: LucideIcons.folderOpen300,
            size: 15,
            tooltip: 'Show in Finder',
            onPressed: () => _reveal(context, ref),
          ),
          const SizedBox(width: 2),
          AppIconButton(
            icon: LucideIcons.squareArrowOutUpRight300,
            size: 15,
            tooltip: selected == null
                ? 'Pick a file to open it'
                : 'Open in the default app',
            // Null disables it rather than hiding it: a button that comes and
            // goes as you click around the tree makes the toolbar twitch.
            onPressed: selected == null
                ? null
                : () => openExternalUrl(selected),
          ),
        ],
      ),
    );
  }
}

/// The folder above [path], or null when there isn't one to speak of.
String? _parentOf(String? path) {
  if (path == null) return null;
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut <= 0 ? null : path.substring(0, cut);
}

/// A chat that belongs to no project has no folder to browse — the fix is a
/// project, which lives one screen away.
class _NoProject extends StatelessWidget {
  const _NoProject();

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: SizedBox.shrink(),
    main: EmptyState(
      icon: LucideIcons.folderOpen,
      title: 'This chat has no project',
      message:
          'Files shows the folder a chat is working in. Open a chat inside a '
          'project to browse it.',
      compact: true,
    ),
  );
}
