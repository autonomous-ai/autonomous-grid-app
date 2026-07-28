import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/external_launch.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../../projects/logic/agent_workspace.dart';
import '../logic/workspace_browser.dart';

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

/// A browser for the folder a chat runs in — where the assistant reads and saves
/// files. It answers "where did the file it just made go?": a loose chat's files
/// land in an app folder the user would otherwise never find, and this shows
/// them, opens them, and reveals the folder itself in the system file manager.
///
/// Walks into subfolders (a real tree) but never above [rootPath], so it can't
/// wander out into the rest of the disk.
class _WorkspaceFilesDialog extends ConsumerStatefulWidget {
  const _WorkspaceFilesDialog({required this.rootPath, required this.rootLabel});

  final String rootPath;
  final String rootLabel;

  @override
  ConsumerState<_WorkspaceFilesDialog> createState() =>
      _WorkspaceFilesDialogState();
}

class _WorkspaceFilesDialogState extends ConsumerState<_WorkspaceFilesDialog> {
  /// The folder currently on screen — starts at the root and moves as the user
  /// drills in or taps back up the breadcrumb.
  late String _path = widget.rootPath;

  void _navigate(String path) => setState(() => _path = path);

  void _open(WorkspaceEntry entry) {
    if (entry.isDirectory) {
      _navigate(entry.path);
      return;
    }
    openExternalUrl(entry.path);
  }

  /// Re-read this folder — the assistant may have added a file since it opened.
  void _refresh() => ref.invalidate(workdirEntriesProvider(_path));

  Future<void> _revealInFinder() async {
    final ok = await ref.read(hostShellServiceProvider).openFolder(_path);
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
    final entries = ref.watch(workdirEntriesProvider(_path));
    return AlertDialog(
      // Lifted off the window like the rename dialog — windowBg on windowBg is an
      // edgeless slab; this fill sits clear of the page on both themes.
      backgroundColor: appMenuFill(),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppGlass.hair),
      ),
      titlePadding: const EdgeInsets.fromLTRB(22, 18, 14, 6),
      contentPadding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      actionsPadding: const EdgeInsets.fromLTRB(22, 4, 18, 16),
      title: _Header(
        segments: breadcrumbSegments(
          rootPath: widget.rootPath,
          rootLabel: widget.rootLabel,
          currentPath: _path,
        ),
        onJumpTo: _navigate,
        onRefresh: _refresh,
        onReveal: _revealInFinder,
      ),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: switch (entries) {
            AsyncData(:final value) => _EntryList(entries: value, onOpen: _open),
            AsyncError() => const _Message(
              'Could not read this folder. It may have been moved or deleted.',
            ),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: AppSpinner(size: SpinnerSize.large)),
            ),
          },
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

/// The dialog's top strip: the breadcrumb trail on the left (each folder a step
/// back up the tree), and the refresh / reveal-in-Finder actions on the right.
class _Header extends StatelessWidget {
  const _Header({
    required this.segments,
    required this.onJumpTo,
    required this.onRefresh,
    required this.onReveal,
  });

  final List<({String label, String path})> segments;
  final ValueChanged<String> onJumpTo;
  final VoidCallback onRefresh;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Breadcrumb(segments: segments, onJumpTo: onJumpTo),
        ),
        const SizedBox(width: 8),
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

/// The folder trail. The current folder is plain text; every folder above it is
/// a button that jumps straight there. Scrolls sideways so a deep path never
/// pushes the actions off the dialog.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.segments, required this.onJumpTo});

  final List<({String label, String path})> segments;
  final ValueChanged<String> onJumpTo;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Icon(
                  LucideIcons.chevronRight300,
                  size: 15,
                  color: AppPalette.textFaint,
                ),
              ),
            _Crumb(
              label: segments[i].label,
              isCurrent: i == segments.length - 1,
              onTap: () => onJumpTo(segments[i].path),
            ),
          ],
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.label,
    required this.isCurrent,
    required this.onTap,
  });

  final String label;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
        color: isCurrent ? AppPalette.textPrimary : AppPalette.textSecondary,
      ),
    );
    // The current folder is where you already are — a label, not a button.
    if (isCurrent) return text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: text,
      ),
    );
  }
}

/// One of the header's round icon actions (refresh, reveal-in-Finder).
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

/// The folder's contents — folders first, then files (the order
/// [readWorkspaceEntries] returns) — lazily built so a full folder stays cheap.
class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries, required this.onOpen});

  final List<WorkspaceEntry> entries;
  final ValueChanged<WorkspaceEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const _Message(
        'This folder is empty. Files the assistant saves while you chat show up '
        'here.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (context, i) =>
          _EntryRow(entry: entries[i], onTap: () => onOpen(entries[i])),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onTap});

  final WorkspaceEntry entry;
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Icon(
                isDir ? LucideIcons.folder300 : LucideIcons.file300,
                size: 17,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              const SizedBox(width: 8),
              // A folder invites a tap inward; a file shows its size instead.
              if (isDir)
                Icon(
                  LucideIcons.chevronRight300,
                  size: 16,
                  color: AppPalette.textFaint,
                )
              else
                Text(
                  workspaceSizeLabel(entry),
                  style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
                ),
            ],
          ),
        ),
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
