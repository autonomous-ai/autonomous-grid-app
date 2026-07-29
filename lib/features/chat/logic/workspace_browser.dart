/// Pure navigation for the chat's file browser: turning a location inside the
/// chat's folder into a breadcrumb trail the user can walk back up.
///
/// Path-string logic only — no filesystem — so it's unit-tested. Paths follow
/// the rest of the workspace code and are `/`-separated (see `readWorkspaceEntries`).
library;

/// Drops a trailing separator so two spellings of the same folder compare equal.
String _trimSlash(String path) => path.length > 1 && path.endsWith('/')
    ? path.substring(0, path.length - 1)
    : path;

/// Whether [path] is [root] or sits inside it.
///
/// The browser never leaves the chat's own folder, so a location that isn't
/// within the root is treated as the root — a guard against a stray path walking
/// the user out into the rest of the disk.
bool isWithinRoot(String path, String root) {
  final p = _trimSlash(path);
  final r = _trimSlash(root);
  return p == r || p.startsWith('$r/');
}

/// The breadcrumb from [rootPath] — shown under the friendly [rootLabel] — down
/// to [currentPath]: one segment per folder, each paired with the path it points
/// at so tapping it jumps straight back up the tree.
///
/// The first segment is always the root; deeper segments carry their real folder
/// names. A [currentPath] outside the root (which the browser never navigates to)
/// collapses to the root alone, so the trail can't offer a step it can't take.
List<({String label, String path})> breadcrumbSegments({
  required String rootPath,
  required String rootLabel,
  required String currentPath,
}) {
  final root = (label: rootLabel, path: rootPath);
  if (!isWithinRoot(currentPath, rootPath)) return [root];

  final rootTrimmed = _trimSlash(rootPath);
  final rest = _trimSlash(currentPath)
      .substring(rootTrimmed.length)
      .split('/')
      .where((name) => name.isNotEmpty);

  final segments = <({String label, String path})>[root];
  var acc = rootTrimmed;
  for (final name in rest) {
    acc = '$acc/$name';
    segments.add((label: name, path: acc));
  }
  return segments;
}
