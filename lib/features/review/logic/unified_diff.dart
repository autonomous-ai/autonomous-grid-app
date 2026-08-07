/// What one line of a diff is.
enum DiffRowKind {
  /// Unchanged, shown for orientation.
  context,
  added,
  removed,

  /// Git's own aside — `\ No newline at end of file`. Not part of the file, so
  /// it carries no line number and is never counted as a change.
  note,
}

/// One line of a file's diff, with the line numbers it has on each side.
///
/// [oldLine] is null for an added line and [newLine] for a removed one — that
/// is exactly what the gutter draws, so the widget never has to work it out.
class DiffRow {
  const DiffRow({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final DiffRowKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

/// A run of changed lines with its surrounding context — one `@@` block.
class DiffHunk {
  const DiffHunk({required this.header, required this.rows});

  /// The `@@ -1,7 +1,9 @@ ClassName.method` line. The part after the second
  /// `@@` is Git's guess at which function the hunk is in — worth showing.
  final String header;
  final List<DiffRow> rows;

  /// What Git wrote after the ranges (the enclosing function, usually), or ''.
  String get context {
    final end = header.indexOf('@@', 2);
    if (end < 0) return '';
    return header.substring(end + 2).trim();
  }
}

/// A file's whole diff, ready to draw.
class DiffFilePatch {
  const DiffFilePatch({
    required this.hunks,
    this.binary = false,
    this.truncatedBy = 0,
  });

  /// A patch with nothing in it — what an unreadable or unchanged file shows.
  static const empty = DiffFilePatch(hunks: []);

  final List<DiffHunk> hunks;

  /// Git refused to show the contents because the file isn't text. The screen
  /// says so instead of drawing an empty pane that reads as "no change".
  final bool binary;

  /// How many rows were dropped to keep the pane drawable. Never silently: the
  /// view has to say a file was cut short (§9).
  final int truncatedBy;

  bool get isEmpty => hunks.isEmpty && !binary;
}

/// The most rows one file's diff may contribute before it is cut short.
///
/// A generated file — a lock file, a bundled asset — can be a single hunk tens
/// of thousands of lines long, and every row is a widget. The cap is high
/// enough that no hand-written change reaches it and low enough that a
/// generated one doesn't take the window down with it.
const int kMaxDiffRows = 4000;

/// Parses the unified diff Git prints for **one** file.
///
/// Written against Git's real output rather than the format's description:
/// `diff --git` headers, `new file mode`, `similarity index`, `--- /dev/null`,
/// `Binary files a/x and b/x differ`, and the `\ No newline at end of file`
/// aside all appear in ordinary use. Everything before the first `@@` is
/// header, and the only header lines that change what's drawn are the binary
/// ones.
///
/// Pure and total: anything it doesn't recognise is skipped, so a diff shape
/// this doesn't know about shows fewer lines rather than throwing over the
/// screen. Rows past [maxRows] are dropped and counted in
/// [DiffFilePatch.truncatedBy].
DiffFilePatch parseUnifiedDiff(String diff, {int maxRows = kMaxDiffRows}) {
  final hunks = <DiffHunk>[];
  var rows = <DiffRow>[];
  var header = '';
  var oldLine = 0;
  var newLine = 0;
  var binary = false;
  var dropped = 0;
  var kept = 0;

  void closeHunk() {
    if (header.isEmpty) return;
    hunks.add(DiffHunk(header: header, rows: List.unmodifiable(rows)));
    rows = <DiffRow>[];
    header = '';
  }

  for (final line in _lines(diff)) {
    if (line.startsWith('@@')) {
      closeHunk();
      final range = _parseHunkHeader(line);
      if (range == null) continue;
      header = line;
      oldLine = range.oldStart;
      newLine = range.newStart;
      continue;
    }
    if (header.isEmpty) {
      // Still in the file header. `Binary files … differ` is the one line here
      // that decides what the pane shows.
      if (line.startsWith('Binary files') || line.startsWith('GIT binary')) {
        binary = true;
      }
      continue;
    }
    if (kept >= maxRows) {
      dropped++;
      continue;
    }
    kept++;
    if (line.startsWith('\\')) {
      rows.add(DiffRow(kind: DiffRowKind.note, text: line.substring(1).trim()));
      continue;
    }
    if (line.startsWith('+')) {
      rows.add(
        DiffRow(
          kind: DiffRowKind.added,
          text: line.substring(1),
          newLine: newLine++,
        ),
      );
      continue;
    }
    if (line.startsWith('-')) {
      rows.add(
        DiffRow(
          kind: DiffRowKind.removed,
          text: line.substring(1),
          oldLine: oldLine++,
        ),
      );
      continue;
    }
    // A context line is prefixed with a space; Git writes a bare empty line for
    // an empty one, which is the same thing with the prefix eaten.
    rows.add(
      DiffRow(
        kind: DiffRowKind.context,
        text: line.isEmpty ? '' : line.substring(1),
        oldLine: oldLine++,
        newLine: newLine++,
      ),
    );
  }
  closeHunk();

  return DiffFilePatch(
    hunks: List.unmodifiable(hunks),
    binary: binary,
    truncatedBy: dropped,
  );
}

/// The diff's lines, without the phantom one the closing newline would leave
/// behind. That phantom would arrive as an empty context row at the end of the
/// last hunk — a line of the file that isn't in the file.
List<String> _lines(String diff) {
  final lines = diff.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// The two starting line numbers in `@@ -12,7 +12,9 @@`, or null when the line
/// isn't a hunk header after all. A range with no comma (`@@ -1 +1 @@`) counts
/// one line.
({int oldStart, int newStart})? _parseHunkHeader(String line) {
  final match = _hunkPattern.firstMatch(line);
  if (match == null) return null;
  final oldStart = int.tryParse(match.group(1) ?? '');
  final newStart = int.tryParse(match.group(2) ?? '');
  if (oldStart == null || newStart == null) return null;
  return (oldStart: oldStart, newStart: newStart);
}

final RegExp _hunkPattern = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
