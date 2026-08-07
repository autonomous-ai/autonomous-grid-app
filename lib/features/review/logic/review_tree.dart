import 'review_file.dart';

/// The files that changed in one folder — one run of rows in the file panel.
class ReviewGroup {
  const ReviewGroup({required this.folder, required this.files});

  /// Relative to the repository root; empty for the root itself.
  final String folder;
  final List<ReviewFile> files;

  /// The heading over the run. The repository root has no path to show, so it
  /// says what it is instead of drawing a blank line.
  String get label => folder.isEmpty ? 'Top level' : folder;
}

/// Groups [files] by the folder they live in, keeping the incoming order.
///
/// A flat list of paths is unreadable once a change spans forty files: every
/// row starts with the same `lib/features/…` and the eye has nothing to catch.
/// Grouping is by full folder path rather than a nesting tree on purpose — a
/// deep tree needs expanding and collapsing to be useful, and the panel is
/// narrow; one heading per folder gets the orientation without the plumbing.
List<ReviewGroup> groupByFolder(List<ReviewFile> files) {
  final byFolder = <String, List<ReviewFile>>{};
  for (final file in files) {
    byFolder.putIfAbsent(file.folder, () => []).add(file);
  }
  return List.unmodifiable([
    for (final entry in byFolder.entries)
      ReviewGroup(folder: entry.key, files: List.unmodifiable(entry.value)),
  ]);
}

/// [files] narrowed to those whose path matches [query], case-insensitively.
///
/// Matches on the whole path, not just the name: "features/review" is how
/// someone narrows to one area, and it is also the only way to tell two
/// `index.dart`s apart. A rename is matched on where it came from as well, so
/// searching for the old name still finds it.
List<ReviewFile> filterFiles(List<ReviewFile> files, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return files;
  return List.unmodifiable([
    for (final file in files)
      if (file.path.toLowerCase().contains(needle) ||
          (file.oldPath?.toLowerCase().contains(needle) ?? false))
        file,
  ]);
}
