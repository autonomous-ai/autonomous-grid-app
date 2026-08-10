/// Pure flattening for a file tree: turning the folders the user has opened
/// into the flat, ordered list of rows the tree draws.
///
/// List logic only — no filesystem, no widgets — so it's unit-tested. The
/// browser reads each folder lazily (only an *expanded* folder's children are
/// fetched), so a row can still be waiting on that read or have failed it; those
/// states ride along in the list, indented under their parent.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_entries.dart';

/// One line in the flattened tree, tagged with its [depth] so the view can
/// indent it without re-walking the hierarchy (0 for a top-level child of the
/// root, +1 per folder deep).
sealed class WorkspaceRow {
  const WorkspaceRow(this.depth);

  final int depth;
}

/// A real file or folder. [isExpanded] is only ever true for a folder the user
/// has opened.
class WorkspaceEntryRow extends WorkspaceRow {
  const WorkspaceEntryRow({
    required this.entry,
    required int depth,
    required this.isExpanded,
  }) : super(depth);

  final WorkspaceEntry entry;
  final bool isExpanded;
}

/// A placeholder under an expanded folder that is still loading its children or
/// failed to read them — [isError] tells the two apart.
class WorkspaceStatusRow extends WorkspaceRow {
  const WorkspaceStatusRow({required int depth, required this.isError})
    : super(depth);

  final bool isError;
}

/// Flatten the tree under [rootEntries] into draw order, descending only into
/// the folders in [expanded].
///
/// [childrenOf] fetches a folder's listing (the async state of its provider).
/// Folders precede files at every level because [rootEntries] and each
/// [childrenOf] result already arrive in that order. A closed — or huge,
/// unopened — folder is never read, so the tree stays cheap until the user asks
/// for it.
List<WorkspaceRow> flattenWorkspaceTree({
  required List<WorkspaceEntry> rootEntries,
  required Set<String> expanded,
  required AsyncValue<List<WorkspaceEntry>> Function(String path) childrenOf,
}) {
  final rows = <WorkspaceRow>[];

  void walk(List<WorkspaceEntry> entries, int depth) {
    for (final entry in entries) {
      final isOpen = entry.isDirectory && expanded.contains(entry.path);
      rows.add(
        WorkspaceEntryRow(entry: entry, depth: depth, isExpanded: isOpen),
      );
      if (!isOpen) continue;
      switch (childrenOf(entry.path)) {
        case AsyncData(:final value):
          walk(value, depth + 1);
        case AsyncError():
          rows.add(WorkspaceStatusRow(depth: depth + 1, isError: true));
        case _:
          rows.add(WorkspaceStatusRow(depth: depth + 1, isError: false));
      }
    }
  }

  walk(rootEntries, 0);
  return rows;
}
