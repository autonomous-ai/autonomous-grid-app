/// Grouping the document's flat paragraph list into the rows the Edit view draws.
///
/// The editor's unit of *editing* is the paragraph, because that is what the save
/// patches. Its unit of *drawing* can't be: a table's paragraphs are cells, and
/// drawing them one under another turns a 4×3 table into twelve loose lines —
/// which is exactly what it looked like before this existed.
///
/// So the lines are grouped here, once, into a display list: a body paragraph, or
/// a whole table. Every cell still carries the line index that writes it back, so
/// grouping changes what is drawn and nothing about what is saved.
library;

import '../../logic/docx_format.dart';

/// One thing the Edit view draws.
sealed class OfficeEditorRow {
  const OfficeEditorRow();
}

/// A paragraph of body text, at line [index].
final class OfficeEditorParagraph extends OfficeEditorRow {
  const OfficeEditorParagraph(this.index);

  final int index;
}

/// A whole table, as the grid it is.
final class OfficeEditorTable extends OfficeEditorRow {
  const OfficeEditorTable({required this.rows, required this.gridTwips});

  /// Its rows, each a list of cells in column order.
  final List<List<OfficeEditorCell>> rows;

  /// The table's column widths (`w:tblGrid`).
  final List<int> gridTwips;
}

/// One cell: which grid columns it covers, and the paragraphs inside it.
final class OfficeEditorCell {
  const OfficeEditorCell({
    required this.column,
    required this.gridSpan,
    required this.lines,
  });

  final int column;
  final int gridSpan;

  /// Line indices of the paragraphs in this cell, in order — usually one.
  final List<int> lines;
}

/// Groups [formats] (one entry per line, in document order) into what to draw.
///
/// Lines past the end of [formats] are paragraphs the user has just created by
/// splitting one; they draw as body text, which is what they are until the file is
/// saved and read again.
List<OfficeEditorRow> editorRows(int lineCount, List<DocxLineFormat> formats) {
  final out = <OfficeEditorRow>[];
  var index = 0;
  while (index < lineCount) {
    final span = index < formats.length ? formats[index].table : null;
    if (span == null) {
      out.add(OfficeEditorParagraph(index));
      index++;
      continue;
    }
    // Every following line that belongs to the same table, gathered into rows and
    // cells. A different table id ends this one even when it starts on the very
    // next line.
    final rows = <List<OfficeEditorCell>>[];
    while (_spanAt(formats, index)?.table == span.table) {
      final row = _spanAt(formats, index)!.row;
      final cells = <OfficeEditorCell>[];
      while (_isAt(formats, index, span.table, row)) {
        final cell = _spanAt(formats, index)!;
        final lines = <int>[];
        // A cell can hold more than one paragraph, and they are consecutive.
        while (_isAt(formats, index, span.table, row, cell.column)) {
          lines.add(index);
          index++;
        }
        cells.add(
          OfficeEditorCell(
            column: cell.column,
            gridSpan: cell.gridSpan,
            lines: lines,
          ),
        );
      }
      rows.add(cells);
    }
    out.add(OfficeEditorTable(rows: rows, gridTwips: span.gridTwips));
  }
  return out;
}

/// The table position of line [index], or null when there is no such line or it
/// isn't in a table — one lookup so the loops above can stay readable.
DocxTableSpan? _spanAt(List<DocxLineFormat> formats, int index) =>
    index >= 0 && index < formats.length ? formats[index].table : null;

/// Whether line [index] is in table [table], row [row] — and, when [column] is
/// given, that cell.
bool _isAt(
  List<DocxLineFormat> formats,
  int index,
  int table,
  int row, [
  int? column,
]) {
  final span = _spanAt(formats, index);
  if (span == null || span.table != table || span.row != row) return false;
  return column == null || span.column == column;
}
