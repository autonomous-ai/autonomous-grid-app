import 'package:flutter/foundation.dart';

import 'unified_diff.dart';

/// One row of a side-by-side diff: what the line was, and what it became.
///
/// Either half may be missing — a line that was only added has nothing on the
/// left, and one that was only removed has nothing on the right. That is the
/// whole reason this type exists: the unified list has no notion of two lines
/// standing opposite each other.
@immutable
class SplitRow {
  const SplitRow({this.before, this.after, this.note});

  /// The line as it was, or null where nothing was there.
  final DiffRow? before;

  /// The line as it is now, or null where nothing is.
  final DiffRow? after;

  /// Git talking about the file rather than a line of it — spans both columns,
  /// because it belongs to neither.
  final DiffRow? note;

  /// Whichever half a comment on this row would point at.
  ///
  /// The new file wins, as it does everywhere else: the number worth quoting is
  /// the one the file has now.
  DiffRow? get anchorRow => after ?? before ?? note;
}

/// Lays a hunk's lines out in two columns.
///
/// Runs of removals and additions are paired *in order* — the first line
/// removed against the first added, and so on — which is what makes a rewritten
/// line read as one change rather than two. A run longer on one side leaves the
/// other half empty rather than sliding the next pair out of step.
///
/// Context lines are the same line on both sides, so they carry themselves
/// twice; that is what keeps the two columns from drifting apart.
List<SplitRow> pairRows(List<DiffRow> rows) {
  final out = <SplitRow>[];
  var i = 0;
  while (i < rows.length) {
    final row = rows[i];
    switch (row.kind) {
      case DiffRowKind.context:
        out.add(SplitRow(before: row, after: row));
        i++;
      case DiffRowKind.note:
        out.add(SplitRow(note: row));
        i++;
      case DiffRowKind.removed:
      case DiffRowKind.added:
        final removed = <DiffRow>[];
        while (i < rows.length && rows[i].kind == DiffRowKind.removed) {
          removed.add(rows[i++]);
        }
        final added = <DiffRow>[];
        while (i < rows.length && rows[i].kind == DiffRowKind.added) {
          added.add(rows[i++]);
        }
        final pairs = removed.length > added.length
            ? removed.length
            : added.length;
        for (var k = 0; k < pairs; k++) {
          out.add(
            SplitRow(
              before: k < removed.length ? removed[k] : null,
              after: k < added.length ? added[k] : null,
            ),
          );
        }
    }
  }
  return List.unmodifiable(out);
}
