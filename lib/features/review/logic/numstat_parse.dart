import 'review_file.dart';

/// How much of one file changed, as `git diff --numstat` reports it.
typedef DiffCount = ({int added, int removed, bool binary});

/// Reads `git diff --numstat -z …` into counts keyed by the file's *current*
/// path — the same key [ReviewFile.path] uses, so [withCounts] can match them
/// up.
///
/// The `-z` form has two shapes, and the second is why this isn't a one-liner:
/// ```
/// 12\t3\tlib/main.dart\0                     ordinary
/// 0\t0\t\0old/name.dart\0new/name.dart\0     rename: paths are separate fields
/// -\t-\tassets/logo.png\0                    binary: nothing to count
/// ```
Map<String, DiffCount> parseNumstat(String stdout) {
  final chunks = stdout.split('\u0000');
  final counts = <String, DiffCount>{};
  for (var i = 0; i < chunks.length; i++) {
    final fields = chunks[i].split('\t');
    if (fields.length < 3) continue;
    // An empty path field means the two paths of a rename follow as their own
    // fields; the second of them is where the file lives now.
    var path = fields[2];
    if (path.isEmpty) {
      if (i + 2 >= chunks.length) break;
      path = chunks[i + 2];
      i += 2;
    }
    if (path.isEmpty) continue;
    final added = int.tryParse(fields[0]);
    final removed = int.tryParse(fields[1]);
    counts[path] = (
      added: added ?? 0,
      removed: removed ?? 0,
      // Git writes `-` for both counts when the file isn't text. Counting
      // "0 lines changed" for a replaced image would be a lie by omission.
      binary: added == null || removed == null,
    );
  }
  return counts;
}

/// [files] with the line counts from [counts] filled in.
///
/// The two come from separate commands — `status` knows *what* happened to a
/// file, `diff --numstat` knows *how much* — and a file may be missing from
/// either: an untracked file has no numstat entry at all (Git isn't tracking
/// it), which is why its count is measured from disk instead (see
/// `untrackedCount`).
List<ReviewFile> withCounts(
  List<ReviewFile> files,
  Map<String, DiffCount> counts,
) => List.unmodifiable([
  for (final file in files)
    if (counts[file.path] case final count?)
      file.copyWith(
        added: count.added,
        removed: count.removed,
        binary: count.binary,
      )
    else
      file,
]);

/// What an untracked file adds, measured from its own contents — every line in
/// it is new. Comes back `binary` when the contents don't look like text, so
/// the screen says so rather than counting bytes as lines.
///
/// Pure, so the file reading stays in the service and this stays testable.
DiffCount untrackedCount(String contents) {
  // A NUL byte is how Git itself decides a file isn't text.
  if (contents.contains('\u0000')) {
    return (added: 0, removed: 0, binary: true);
  }
  if (contents.isEmpty) return (added: 0, removed: 0, binary: false);
  final lines = contents.split('\n');
  // A trailing newline ends the last line, it doesn't start another one.
  final count = lines.last.isEmpty ? lines.length - 1 : lines.length;
  return (added: count, removed: 0, binary: false);
}
