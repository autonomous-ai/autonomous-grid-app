/// Narrowing the file tree to what the filter box says.
///
/// List logic only — no filesystem, no widgets.
library;

import '../../chat/logic/workspace_browser.dart';

/// Keep the rows whose name matches [query], plus every folder above one.
///
/// A match with its ancestors dropped is a name floating free of where it
/// lives; keeping the folders is what makes the result still read as a tree.
///
/// **Only searches what the tree has already loaded.** Folders read lazily, on
/// being opened, so a file inside a folder the user has never expanded is not
/// here to be matched — the same as type-ahead in an editor's explorer. The
/// empty state says so, rather than letting the user read "nothing" as "no such
/// file".
///
/// The loading and error placeholders drop out while a filter is on: neither
/// has a name, so neither can be said to match.
List<WorkspaceRow> filterWorkspaceRows(List<WorkspaceRow> rows, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return rows;

  final keep = List<bool>.filled(rows.length, false);
  // Backwards, so a folder is judged after everything nested under it: its own
  // descendants are the rows that follow it while the depth stays greater.
  for (var i = rows.length - 1; i >= 0; i--) {
    final row = rows[i];
    if (row is! WorkspaceEntryRow) continue;
    if (row.entry.name.toLowerCase().contains(needle)) {
      keep[i] = true;
      continue;
    }
    for (var j = i + 1; j < rows.length && rows[j].depth > row.depth; j++) {
      if (!keep[j]) continue;
      keep[i] = true;
      break;
    }
  }

  return [
    for (var i = 0; i < rows.length; i++)
      if (keep[i]) rows[i],
  ];
}
