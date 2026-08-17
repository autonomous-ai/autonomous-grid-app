import 'package:flutter/material.dart';

import '../../logic/docx/docx_model.dart';
import 'docx_block_view.dart';

/// A table, drawn from its grid.
///
/// Rows of sized boxes rather than Flutter's `Table`, and for one reason:
/// `w:gridSpan`. A Word table merges cells constantly — a heading across three
/// columns, a label spanning two — and `Table` has no colspan at all, so a table
/// built with it puts the wrong text under the wrong heading. Here a spanning
/// cell is simply a box as wide as the columns it covers, which is what the grid
/// already says.
///
/// [IntrinsicHeight] is what makes a row's borders line up: without it each cell
/// is as tall as its own text and the frame comes out ragged.
class DocxTableView extends StatelessWidget {
  const DocxTableView({
    super.key,
    required this.doc,
    required this.table,
    required this.markers,
    required this.availableWidth,
  });

  final ParsedDocx doc;
  final DocxTable table;

  /// The document's list markers, passed down so a numbered list inside a cell
  /// keeps counting with the rest of the document.
  final List<String?> markers;

  /// The column the table has to fit in. A table wider than the page is scaled
  /// down rather than clipped — Word would have laid it out to fit, and a table
  /// with its last column off the edge of the paper is unreadable.
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final widths = _columnWidths();
    if (widths.isEmpty || table.rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
        left: twipsToPx(table.indentTwips ?? 0),
        // Word's own air around a table: without it a table butts against the
        // paragraph above and below.
        top: 4,
        bottom: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < table.rows.length; row++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _cells(table.rows[row], widths),
              ),
            ),
        ],
      ),
    );
  }

  /// The grid, scaled to fit and never zero-width.
  ///
  /// A missing `w:tblGrid` is not unusual in files from converters; falling back
  /// to equal columns from the first row keeps such a table readable instead of
  /// collapsing it.
  List<double> _columnWidths() {
    final grid = table.gridTwips.where((w) => w > 0).toList();
    if (grid.isEmpty) {
      final columns = table.rows.first.cells.length;
      if (columns == 0) return const [];
      return List.filled(columns, availableWidth / columns);
    }
    final total = grid.fold<int>(0, (sum, w) => sum + w);
    final natural = twipsToPx(total);
    final scale = natural > availableWidth ? availableWidth / natural : 1.0;
    return [for (final w in grid) twipsToPx(w) * scale];
  }

  List<Widget> _cells(DocxTableRow row, List<double> widths) {
    final cells = <Widget>[];
    var column = 0;
    for (final cell in row.cells) {
      if (column >= widths.length) break;
      final span = cell.gridSpan.clamp(1, widths.length - column);
      var width = 0.0;
      for (var i = 0; i < span; i++) {
        width += widths[column + i];
      }
      cells.add(
        _Cell(
          doc: doc,
          cell: cell,
          table: table,
          markers: markers,
          width: width,
        ),
      );
      column += span;
    }
    return cells;
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.doc,
    required this.cell,
    required this.table,
    required this.markers,
    required this.width,
  });

  final ParsedDocx doc;
  final DocxTableCell cell;
  final DocxTable table;
  final List<String?> markers;
  final double width;

  /// Word's default cell padding when neither the table nor its style says:
  /// 0 top and bottom, 108 twips (0.075") left and right.
  static const _defaultMargins = [0, 108, 0, 108];

  @override
  Widget build(BuildContext context) {
    final margins = table.cellMarginsTwips ?? _defaultMargins;
    final inner = width - twipsToPx(margins[1]) - twipsToPx(margins[3]);
    return Container(
      width: width,
      decoration: BoxDecoration(color: _fill(), border: _border()),
      padding: EdgeInsets.fromLTRB(
        twipsToPx(margins[1]),
        twipsToPx(margins[0]),
        twipsToPx(margins[3]),
        twipsToPx(margins[2]),
      ),
      // A cell continuing a vertical merge draws its neighbour's content, not its
      // own — the text belongs to the cell that started the merge.
      child: cell.vMergeContinue
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final block in cell.blocks)
                  DocxBlockView(
                    doc: doc,
                    block: block,
                    markers: markers,
                    availableWidth: inner > 0 ? inner : width,
                    inTable: true,
                  ),
              ],
            ),
    );
  }

  Color? _fill() {
    final fill = cell.shadingFill;
    if (fill == null || fill.length < 6) return null;
    final parsed = int.tryParse(fill.substring(0, 6), radix: 16);
    return parsed == null ? null : Color(0xFF000000 | parsed);
  }

  /// The cell's own frame where it has one, the table's where it doesn't — which
  /// is the inheritance `w:tcBorders` over `w:tblBorders` describes.
  ///
  /// Every cell draws all four of its sides, so shared edges are drawn twice.
  /// That is deliberate: collapsing them would need to know each neighbour's
  /// borders, and a doubled hairline at the same width is invisible, while a
  /// missing one is a table with holes in its frame.
  Border? _border() {
    final own = cell.borders;
    final table = this.table.borders;
    BorderSide side(DocxBorderSide? cellSide, DocxBorderSide? tableSide) {
      final resolved = cellSide ?? tableSide;
      if (resolved == null || !resolved.visible) return BorderSide.none;
      return BorderSide(color: _color(resolved.color), width: resolved.widthPx);
    }

    if (own == null && table == null) return null;
    return Border(
      top: side(own?.top, table?.top),
      left: side(own?.left, table?.left),
      bottom: side(own?.bottom, table?.bottom),
      right: side(own?.right, table?.right),
    );
  }

  Color _color(String hex) {
    final parsed = hex.length >= 6
        ? int.tryParse(hex.substring(0, 6), radix: 16)
        : null;
    return parsed == null
        ? const Color(0xFF000000)
        : Color(0xFF000000 | parsed);
  }
}
