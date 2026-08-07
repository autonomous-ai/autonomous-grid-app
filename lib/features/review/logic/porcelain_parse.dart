import 'review_file.dart';

/// Reads `git status --porcelain=v2 -z --untracked-files=all` into the file
/// list the screen shows.
///
/// Porcelain **v2** rather than the familiar `XY path` of v1: v1 quotes and
/// escapes paths with non-ASCII characters, so a Vietnamese filename comes back
/// mangled, and its rename form is ambiguous. v2 with `-z` hands over raw bytes
/// and gives a rename its own record — at the cost of the quirk this parser
/// exists for: a rename's *original* path is a separate NUL-terminated field
/// after the record, so the fields cannot simply be split and mapped.
///
/// Record shapes (see `git status --help`, "Porcelain Format Version 2"):
/// ```
/// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
/// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\0<origPath>
/// u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
/// ? <path>
/// ```
/// `X` is what the index holds, `Y` what the working tree does; `.` means "no
/// change on that side".
///
/// Unparsable records are skipped rather than thrown over: a status listing
/// that gained a record type must not blank the whole screen.
List<ReviewFile> parsePorcelainV2(String stdout) {
  final chunks = stdout.split('\u0000');
  final files = <ReviewFile>[];
  for (var i = 0; i < chunks.length; i++) {
    final record = chunks[i];
    if (record.length < 3) continue;
    switch (record[0]) {
      case '1':
        final path = _afterFields(record, 8);
        if (path == null) continue;
        files.add(
          ReviewFile(
            path: path,
            kind: _ordinaryKind(record[2], record[3]),
            staged: record[2] != '.',
          ),
        );
      case '2':
        final path = _afterFields(record, 9);
        // The original path is the next field, not part of this record.
        final origPath = i + 1 < chunks.length ? chunks[++i] : null;
        if (path == null || origPath == null || origPath.isEmpty) continue;
        // A copy (`C`) leaves the original where it was, so calling it a rename
        // would claim a file moved that didn't.
        final copied = record[2] == 'C' || record[3] == 'C';
        files.add(
          ReviewFile(
            path: path,
            kind: copied ? ReviewFileKind.added : ReviewFileKind.renamed,
            oldPath: copied ? null : origPath,
            staged: record[2] != '.',
          ),
        );
      case 'u':
        final path = _afterFields(record, 10);
        if (path == null) continue;
        files.add(ReviewFile(path: path, kind: ReviewFileKind.conflicted));
      case '?':
        final path = _afterFields(record, 1);
        if (path == null) continue;
        files.add(ReviewFile(path: path, kind: ReviewFileKind.untracked));
      // '!' (ignored) and '#' (branch headers) are not changes to review.
    }
  }
  return sortedByPath(files);
}

/// Reads `git diff --name-status -M -z <base> HEAD` — the branch comparison,
/// where there is no index and no working tree, only what the commits did.
///
/// Fields alternate status and path, except a rename/copy (`R100`, `C75`),
/// whose status is followed by *two* paths: where the file was and where it is.
List<ReviewFile> parseNameStatus(String stdout) {
  final chunks = stdout.split('\u0000');
  final files = <ReviewFile>[];
  for (var i = 0; i + 1 < chunks.length; i++) {
    final status = chunks[i];
    if (status.isEmpty) continue;
    final letter = status[0];
    if (letter == 'R' || letter == 'C') {
      if (i + 2 >= chunks.length) break;
      final origPath = chunks[i + 1];
      final path = chunks[i + 2];
      i += 2;
      files.add(
        ReviewFile(
          path: path,
          kind: letter == 'C' ? ReviewFileKind.added : ReviewFileKind.renamed,
          oldPath: letter == 'C' ? null : origPath,
          staged: true,
        ),
      );
      continue;
    }
    final path = chunks[++i];
    if (path.isEmpty) continue;
    files.add(
      ReviewFile(
        path: path,
        kind: switch (letter) {
          'A' => ReviewFileKind.added,
          'D' => ReviewFileKind.deleted,
          'U' => ReviewFileKind.conflicted,
          _ => ReviewFileKind.modified,
        },
        // Everything here is already committed on the branch — there is nothing
        // left to stage, and the screen must not offer it.
        staged: true,
      ),
    );
  }
  return sortedByPath(files);
}

/// Folder-first, then name: the order a file tree reads in, and stable so the
/// list doesn't reshuffle under the cursor between two refreshes.
List<ReviewFile> sortedByPath(List<ReviewFile> files) {
  final sorted = [...files]..sort((a, b) => a.path.compareTo(b.path));
  return List.unmodifiable(sorted);
}

/// What an ordinary (`1`) record did, from the index status [x] and the working
/// tree status [y]. Either side may be `.` for "nothing happened here".
ReviewFileKind _ordinaryKind(String x, String y) {
  final change = x == '.' ? y : x;
  return switch (change) {
    'A' => ReviewFileKind.added,
    'D' => ReviewFileKind.deleted,
    _ => ReviewFileKind.modified,
  };
}

/// Everything after the first [count] space-separated fields of [record], or
/// null when it doesn't have that many.
///
/// Not `split(' ')`: the last field is a path, and a path may contain spaces —
/// splitting would cut "my notes/todo.txt" in half.
String? _afterFields(String record, int count) {
  var cut = -1;
  for (var field = 0; field < count; field++) {
    cut = record.indexOf(' ', cut + 1);
    if (cut < 0) return null;
  }
  final path = record.substring(cut + 1);
  return path.isEmpty ? null : path;
}
