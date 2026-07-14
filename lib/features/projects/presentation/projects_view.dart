import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../agent/logic/agent_providers.dart';
import '../logic/agent_workspace.dart';

/// The Projects screen: the assistant's folder on this computer — the files it is
/// allowed to open while it answers you.
///
/// Put a document, a spreadsheet, a bit of code in there and you can ask about it
/// without pasting anything into the chat. Adding files is a drag-and-drop job,
/// so the screen hands the folder to Finder rather than building a worse copy of
/// it.
class ProjectsView extends ConsumerWidget {
  const ProjectsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(workspaceEntriesProvider);
    final path = ref.watch(agentWorkspaceDirProvider).path;

    return SectionScaffold(
      title: 'Projects',
      subtitle:
          'Files the assistant can read while it answers you. It can open what '
          "is in here — it can't change or delete any of it.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FolderBar(path: path),
          const SizedBox(height: 14),
          Expanded(
            child: switch (entries) {
              AsyncData(:final value) when value.isEmpty => const _Empty(),
              AsyncData(:final value) => _EntryList(entries: value),
              AsyncError(:final error) => ErrorBox(
                message: "Couldn't read the assistant's folder: $error",
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

/// Where the folder is, and the two things you can do with it: open it (to drop
/// files in) and re-read it (once you have).
class _FolderBar extends ConsumerStatefulWidget {
  const _FolderBar({required this.path});

  final String path;

  @override
  ConsumerState<_FolderBar> createState() => _FolderBarState();
}

class _FolderBarState extends ConsumerState<_FolderBar> {
  Future<void> _openFolder() async {
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(widget.path);
    if (!mounted || opened) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("Couldn't open ${widget.path}")));
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.folder_open_rounded, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Refresh',
            iconSize: 18,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(workspaceEntriesProvider),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _openFolder,
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 16),
            label: const Text('Open folder'),
          ),
        ],
      ),
    );
  }
}

/// What's in the folder today.
class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries});

  final List<WorkspaceEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _EntryTile(entry: entries[i]),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final WorkspaceEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            entry.isDirectory
                ? Icons.folder_rounded
                : Icons.description_outlined,
            size: 17,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            workspaceSizeLabel(entry),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Nothing in the folder yet — say what to put there and how, don't just show a
/// blank page.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 34,
              color: AppPalette.textFaint,
            ),
            SizedBox(height: 14),
            Text(
              'No files yet.',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Open the folder above and drop in a document, some notes or a '
              'bit of code. Then ask about it in a chat — the assistant can '
              'read whatever is in here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
