import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_providers.dart';

/// One thing sitting in the assistant's folder — a file it can read, or a folder
/// of them.
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;

  /// Size of a file; 0 for a folder (we don't walk it — a deep tree would make
  /// opening the screen slow for a number nobody reads).
  final int sizeBytes;
  final DateTime modified;
}

/// What's in the assistant's folder right now, folders first then files, each
/// group alphabetical — the order a file manager would show, so the screen and
/// Finder agree.
///
/// Refresh with `ref.invalidate` after the user has been off adding files.
final workspaceEntriesProvider = FutureProvider<List<WorkspaceEntry>>(
  (ref) => readWorkspaceEntries(ref.watch(agentWorkspaceDirProvider)),
);

/// The top-level entries of any [dir] — the same listing as
/// [workspaceEntriesProvider] but for a folder chosen at call time, so the
/// `@`-mention menu can list whichever project a chat is open in. A missing or
/// unreadable folder lists nothing rather than throwing.
final workdirEntriesProvider =
    FutureProvider.family<List<WorkspaceEntry>, String>(
      (ref, path) => readWorkspaceEntries(Directory(path)),
    );

/// List [dir]'s immediate children — folders first, then files, each group
/// alphabetical (the order a file manager shows). OS dotfiles are skipped. Not
/// recursive: a deep tree would make the caller slow for little gain.
Future<List<WorkspaceEntry>> readWorkspaceEntries(Directory dir) async {
  if (!dir.existsSync()) return const [];
  final entries = <WorkspaceEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    final name = entity.path.split('/').last;
    // Skip the dotfiles the OS leaves behind (.DS_Store) — they aren't the
    // user's files and would only be noise in the list.
    if (name.startsWith('.')) continue;
    final stat = await entity.stat();
    entries.add(
      WorkspaceEntry(
        name: name,
        path: entity.path,
        isDirectory: entity is Directory,
        sizeBytes: entity is File ? stat.size : 0,
        modified: stat.modified,
      ),
    );
  }

  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

/// A short, human size for a file ("4.2 MB"). Folders have none.
String workspaceSizeLabel(WorkspaceEntry entry) {
  if (entry.isDirectory) return 'Folder';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = entry.sizeBytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}
