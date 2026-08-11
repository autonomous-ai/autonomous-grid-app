/// Turning absolute paths into the pieces the breadcrumb draws.
///
/// String logic only — no filesystem, no `dart:io`. Separators are handled by
/// accepting both, rather than by asking the platform: the app runs on three,
/// and a path read off disk on one of them can still be looked at on another.
library;

/// One step of the breadcrumb: what it is called, and what it *is*.
///
/// The path rides along because a crumb is no longer only a label — hovering one
/// opens the folder behind it, and a name on its own can't say which folder that
/// is when two levels share it (`src/app`, `test/app`).
typedef FileCrumb = ({String name, String path, bool isDirectory});

/// The crumbs for [filePath] under [root]: the root folder's own name, then each
/// folder down to the file.
///
/// Just the root when nothing is selected, or when the selection turns out not
/// to live under the root at all — a path from somewhere else is shown as "not
/// from here" rather than as a chain of `..` the user has to decode.
///
/// [rootName] replaces the first crumb's label for a folder whose name on disk
/// isn't the name the user knows it by — the app's own `agent-workspace` is
/// "Workspace" everywhere it is shown.
List<FileCrumb> filePathCrumbs({
  required String root,
  String? filePath,
  String? rootName,
}) {
  final rootParts = pathSegments(root);
  final rootCrumb = (
    name: rootName ?? rootParts.lastOrNull ?? root,
    path: root,
    isDirectory: true,
  );
  if (filePath == null) return [rootCrumb];

  final fileParts = pathSegments(filePath);
  if (fileParts.length <= rootParts.length) return [rootCrumb];
  for (var i = 0; i < rootParts.length; i++) {
    if (fileParts[i] != rootParts[i]) return [rootCrumb];
  }

  // Each step's path is built by growing the one before it, so a crumb's path is
  // the real path on disk rather than a re-join that would drop the root's own
  // leading slash or its drive letter.
  final crumbs = [rootCrumb];
  var path = root;
  final tail = fileParts.sublist(rootParts.length);
  for (var i = 0; i < tail.length; i++) {
    path = '$path/${tail[i]}';
    crumbs.add((
      name: tail[i],
      path: path,
      // Everything above the last step is a folder; the last one is the file
      // that was selected.
      isDirectory: i < tail.length - 1,
    ));
  }
  return crumbs;
}

/// A path's non-empty segments, split on either separator.
///
/// Empties are dropped, so a trailing slash or a doubled one doesn't become a
/// blank crumb.
List<String> pathSegments(String path) =>
    path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();

/// The folder above [path], or null when there isn't one to speak of.
String? parentFolderOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut <= 0 ? null : path.substring(0, cut);
}
