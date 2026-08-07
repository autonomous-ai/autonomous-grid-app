/// Turning absolute paths into the pieces the breadcrumb draws.
///
/// String logic only — no filesystem, no `dart:io`. Separators are handled by
/// accepting both, rather than by asking the platform: the app runs on three,
/// and a path read off disk on one of them can still be looked at on another.
library;

/// The crumbs for [filePath] under [root]: the root folder's own name, then
/// each folder down to the file.
///
/// Just the root's name when nothing is selected, or when the selection turns
/// out not to live under the root at all — a path from somewhere else is shown
/// as "not from here" rather than as a chain of `..` the user has to decode.
List<String> filePathCrumbs({required String root, String? filePath}) {
  final rootName = pathSegments(root).lastOrNull ?? root;
  if (filePath == null) return [rootName];

  final rootParts = pathSegments(root);
  final fileParts = pathSegments(filePath);
  if (fileParts.length <= rootParts.length) return [rootName];
  for (var i = 0; i < rootParts.length; i++) {
    if (fileParts[i] != rootParts[i]) return [rootName];
  }
  return [rootName, ...fileParts.sublist(rootParts.length)];
}

/// A path's non-empty segments, split on either separator.
///
/// Empties are dropped, so a trailing slash or a doubled one doesn't become a
/// blank crumb.
List<String> pathSegments(String path) =>
    path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
