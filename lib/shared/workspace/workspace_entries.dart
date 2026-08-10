import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Either separator, because the app runs on three platforms and a path read
/// off disk on one of them can still be looked at on another.
final _separator = RegExp(r'[/\\]');

/// One thing sitting in a folder the app is browsing — a file to read, or a
/// folder of them.
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

/// Which folder to list, and whether its dotfiles count.
///
/// The flag is part of the *key*, not a setting read inside: two callers asking
/// about one folder want two different answers, and a single cached listing
/// would hand whichever asked first to both.
typedef WorkdirQuery = ({String path, bool hidden});

/// The top-level entries of a folder chosen at call time — what lets the
/// `@`-mention menu list whichever project a chat is open in, and the Files
/// panel list whichever folder the user has opened. A missing or unreadable
/// folder lists nothing rather than throwing.
final workdirEntriesProvider =
    FutureProvider.family<List<WorkspaceEntry>, WorkdirQuery>(
      (ref, query) => readWorkspaceEntries(
        Directory(query.path),
        includeHidden: query.hidden,
      ),
    );

/// List [dir]'s immediate children — folders first, then files, each group
/// alphabetical (the order a file manager shows). Not recursive: a deep tree
/// would make the caller slow for little gain.
///
/// Dotfiles are left out unless [includeHidden] says otherwise. Two callers,
/// two right answers: a picker offering the assistant something to read should
/// not lead with `.DS_Store`, while a file browser that quietly dropped
/// `.github`, `.env` and `.gitignore` would be lying about what is in the
/// project.
Future<List<WorkspaceEntry>> readWorkspaceEntries(
  Directory dir, {
  bool includeHidden = false,
}) async {
  if (!await dir.exists()) return const [];
  final entries = <WorkspaceEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    // Split on either separator: Windows hands back `C:\proj\lib\main.dart`, and
    // cutting that on `/` alone leaves the whole path as the name — which then
    // fails the dotfile test, sorts by path instead of name, and reaches the
    // tree as a row labelled with an absolute path.
    final name = entity.path.split(_separator).last;
    if (!includeHidden && name.startsWith('.')) continue;
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
