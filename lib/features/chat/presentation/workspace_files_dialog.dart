import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/external_launch.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../../../shared/workspace/workspace_entries.dart';
import '../../../shared/workspace/workspace_tree.dart';

/// Opens the file browser for the chat's working folder — [rootPath] under the
/// friendly [rootLabel] — so the user can find and open the files the assistant
/// created there. See [_WorkspaceFilesDialog].
Future<void> showWorkspaceFilesDialog(
  BuildContext context, {
  required String rootPath,
  required String rootLabel,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _WorkspaceFilesDialog(rootPath: rootPath, rootLabel: rootLabel),
);

/// Left indent added per folder deep, so nesting reads at a glance.
const double _kIndentStep = 16;

/// A browser for the folder a chat runs in — where the assistant reads and saves
/// files. It answers "where did the file it just made go?": a loose chat's files
/// land in an app folder the user would otherwise never find, and this shows
/// them, opens them, and reveals the folder itself in the system file manager.
///
/// Shown as a live **tree**: folders expand in place, so the whole shape of the
/// workspace stays on screen instead of the user drilling in and losing their
/// place. Each folder's contents load only when it's opened, so a big project
/// folder stays cheap until asked. It never reaches above [rootPath].
class _WorkspaceFilesDialog extends ConsumerStatefulWidget {
  const _WorkspaceFilesDialog({
    required this.rootPath,
    required this.rootLabel,
  });

  final String rootPath;
  final String rootLabel;

  @override
  ConsumerState<_WorkspaceFilesDialog> createState() =>
      _WorkspaceFilesDialogState();
}

class _WorkspaceFilesDialogState extends ConsumerState<_WorkspaceFilesDialog> {
  /// Paths of the folders the user has opened. The root's children are always
  /// shown; this is everything expanded beneath them.
  final Set<String> _expanded = {};

  void _toggle(String path) => setState(() {
    // remove() reports whether it was open; if it wasn't, open it.
    if (!_expanded.remove(path)) _expanded.add(path);
  });

  void _collapseAll() => setState(_expanded.clear);

  void _openFile(WorkspaceEntry entry) => openExternalUrl(entry.path);

  /// Re-read the tree — the assistant may have added files since it opened. One
  /// invalidate refreshes every folder listing the tree has loaded.
  void _refresh() => ref.invalidate(workdirEntriesProvider);

  Future<void> _revealInFinder() async {
    final ok = await ref
        .read(hostShellServiceProvider)
        .openFolder(widget.rootPath);
    if (ok || !mounted) return;
    ToastScope.show(
      context,
      const ToastSpec(
        message: "Couldn't open the folder.",
        severity: ToastSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dialog content is a detached overlay — nothing above rebuilds it on a
    // theme flip, so it watches the brightness itself.
    AppTheme.watch(context);
    return AlertDialog(
      // Lifted off the window like the rename dialog — windowBg on windowBg is an
      // edgeless slab; this fill sits clear of the page on both themes.
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppGlass.hair),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 14, 8),
      contentPadding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      actionsPadding: const EdgeInsets.fromLTRB(22, 4, 18, 16),
      title: _Header(
        title: widget.rootLabel,
        canCollapse: _expanded.isNotEmpty,
        onCollapseAll: _collapseAll,
        onRefresh: _refresh,
        onReveal: _revealInFinder,
      ),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: _Tree(
            rootPath: widget.rootPath,
            expanded: _expanded,
            onToggle: _toggle,
            onOpenFile: _openFile,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The dialog's top strip: the root folder's name on the left, and the
/// collapse-all / refresh / reveal-in-Finder actions on the right.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.canCollapse,
    required this.onCollapseAll,
    required this.onRefresh,
    required this.onReveal,
  });

  final String title;
  final bool canCollapse;
  final VoidCallback onCollapseAll;
  final VoidCallback onRefresh;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(LucideIcons.folder300, size: 17, color: AppPalette.textSecondary),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (canCollapse)
          _IconAction(
            icon: LucideIcons.chevronsDownUp300,
            tooltip: 'Collapse all',
            onTap: onCollapseAll,
          ),
        _IconAction(
          icon: LucideIcons.refreshCw300,
          tooltip: 'Refresh',
          onTap: onRefresh,
        ),
        _IconAction(
          icon: LucideIcons.folderOpen300,
          tooltip: 'Reveal in Finder',
          onTap: onReveal,
        ),
      ],
    );
  }
}

/// One of the header's round icon actions (collapse-all, refresh, reveal).
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 17,
      visualDensity: VisualDensity.compact,
      color: AppPalette.textSecondary,
      icon: Icon(icon),
    );
  }
}

/// The tree body: watches the root folder and, once it's read, flattens the
/// expanded folders into the ordered rows the list draws. Empty / error / first
/// load each get a quiet centred line instead of a bare list.
class _Tree extends ConsumerWidget {
  const _Tree({
    required this.rootPath,
    required this.expanded,
    required this.onToggle,
    required this.onOpenFile,
  });

  final String rootPath;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;
  final ValueChanged<WorkspaceEntry> onOpenFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(
      workdirEntriesProvider((path: rootPath, hidden: false)),
    );
    return switch (root) {
      AsyncData(:final value) when value.isEmpty => const _Message(
        'This folder is empty. Files the assistant saves while you chat show up '
        'here.',
      ),
      AsyncData(:final value) => _TreeList(
        // Each expanded folder is read lazily here; watching happens in build,
        // so a folder's children re-fetch when the user opens it.
        rows: flattenWorkspaceTree(
          rootEntries: value,
          expanded: expanded,
          childrenOf: (path) =>
              ref.watch(workdirEntriesProvider((path: path, hidden: false))),
        ),
        onToggle: onToggle,
        onOpenFile: onOpenFile,
      ),
      AsyncError() => const _Message(
        'Could not read this folder. It may have been moved or deleted.',
      ),
      _ => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: AppSpinner(size: SpinnerSize.large)),
      ),
    };
  }
}

/// Draws the flattened [rows] lazily — a big expanded folder builds only the
/// rows on screen.
class _TreeList extends StatelessWidget {
  const _TreeList({
    required this.rows,
    required this.onToggle,
    required this.onOpenFile,
  });

  final List<WorkspaceRow> rows;
  final ValueChanged<String> onToggle;
  final ValueChanged<WorkspaceEntry> onOpenFile;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows.length,
      itemBuilder: (context, i) => switch (rows[i]) {
        WorkspaceEntryRow(:final entry, :final depth, :final isExpanded) =>
          _EntryRow(
            entry: entry,
            depth: depth,
            isExpanded: isExpanded,
            onTap: () =>
                entry.isDirectory ? onToggle(entry.path) : onOpenFile(entry),
          ),
        WorkspaceStatusRow(:final depth, :final isError) => _StatusRow(
          depth: depth,
          isError: isError,
        ),
      },
    );
  }
}

/// One file or folder in the tree. A folder shows a chevron that turns as it
/// opens and a tap toggles it; a file shows its size and a tap opens it.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.depth,
    required this.isExpanded,
    required this.onTap,
  });

  final WorkspaceEntry entry;
  final int depth;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDir = entry.isDirectory;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        hoverColor: AppSurface.hoverFill,
        child: Padding(
          padding: EdgeInsets.only(
            left: 10 + depth * _kIndentStep,
            right: 10,
            top: 8,
            bottom: 8,
          ),
          child: Row(
            children: [
              // The chevron slot: a folder fills it, a file leaves it blank so
              // its icon still lines up under its sibling folders'.
              SizedBox(
                width: 16,
                child: isDir
                    ? AnimatedRotation(
                        turns: isExpanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(
                          LucideIcons.chevronRight300,
                          size: 15,
                          color: AppPalette.textFaint,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 3),
              Icon(
                isDir
                    ? (isExpanded
                          ? LucideIcons.folderOpen300
                          : LucideIcons.folder300)
                    : LucideIcons.file300,
                size: 16,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              if (!isDir) ...[
                const SizedBox(width: 8),
                Text(
                  workspaceSizeLabel(entry),
                  style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The loading / error line shown inside an expanded folder while its contents
/// arrive or after they fail — indented to sit under that folder's children.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.depth, required this.isError});

  final int depth;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Line up with the child names one level in: past the chevron + icon slot.
      padding: EdgeInsets.only(
        left: 10 + depth * _kIndentStep + 19,
        right: 10,
        top: 7,
        bottom: 7,
      ),
      child: isError
          ? Text(
              'Couldn’t open this folder.',
              style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
            )
          : Row(
              children: [
                const AppSpinner(size: SpinnerSize.small),
                const SizedBox(width: 10),
                Text(
                  'Loading…',
                  style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
                ),
              ],
            ),
    );
  }
}

/// The empty / error line — a quiet, centred sentence.
class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 34),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}
