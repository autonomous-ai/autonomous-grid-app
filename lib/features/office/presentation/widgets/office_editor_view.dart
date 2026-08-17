import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/docx_format.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';
import 'office_editor_rows.dart';

/// The document, editable, on paper — a caret you can put in a paragraph and
/// type.
///
/// **One field per paragraph**, which is the whole design. A paragraph is what
/// Word formats and what `docx_edit.dart` patches, so making it the unit of
/// editing means the thing under the caret and the thing that gets written are
/// the same thing. One field for the whole document can't do it: alignment,
/// indents and spacing are per paragraph, and a single `TextField` has one of
/// each.
///
/// The formatting shown is the shallow read from `docx_format.dart` — enough that
/// a heading looks like a heading and a centred line stays centred. The Read view
/// is the faithful one; this is the one you can type in.
///
/// Tables are drawn as tables and their cells can be typed in (see
/// `office_editor_rows.dart` for how the flat paragraph list is grouped back into
/// a grid). Pictures are not drawn here at all — the paragraph holding one shows a
/// placeholder, because an empty gap where an image is reads as a document that
/// lost it.
class OfficeEditorView extends ConsumerStatefulWidget {
  const OfficeEditorView({super.key, required this.doc});

  final OfficeDocOpen doc;

  /// A Letter-ish column. The Read view draws the document's real page size; this
  /// one only needs a comfortable measure to type in.
  static const _pageWidth = 816.0;

  @override
  ConsumerState<OfficeEditorView> createState() => _OfficeEditorViewState();
}

class _OfficeEditorViewState extends ConsumerState<OfficeEditorView> {
  /// One controller and one focus node per paragraph, made when the paragraph is
  /// first drawn and kept while the document is open.
  ///
  /// Keyed by line index, which changes when a paragraph is split — so a split
  /// clears both maps rather than leaving field 7 holding paragraph 8's text. The
  /// text all lives in the controller's state, so throwing these away costs
  /// nothing but the caret, which the split places deliberately.
  final _fields = <int, TextEditingController>{};
  final _focus = <int, FocusNode>{};

  /// Where to put the caret after the tree rebuilds — set by a split.
  int? _focusLine;

  @override
  void didUpdateWidget(OfficeEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different opening of a document is a different document as far as the
    // fields are concerned, even when the path is the same (see `openId`).
    if (widget.doc.openId != oldWidget.doc.openId) _reset();
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  void _reset() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    _fields.clear();
    _focus.clear();
  }

  List<String> get _lines => widget.doc.text.split('\n');

  /// The format of paragraph [index] — or of the paragraph it was split from,
  /// which has no entry of its own yet.
  DocxLineFormat _formatFor(int index) {
    final formats = widget.doc.formats;
    if (formats.isEmpty) return DocxLineFormat.fallback;
    return formats[index < formats.length ? index : formats.length - 1];
  }

  TextEditingController _controllerFor(int index, String text) =>
      _fields.putIfAbsent(index, () => TextEditingController(text: text));

  FocusNode _focusFor(int index) =>
      _focus.putIfAbsent(index, () => FocusNode());

  void _split(int index, TextEditingController controller) {
    final at = controller.selection.baseOffset;
    ref
        .read(officeDocProvider.notifier)
        .splitLine(index, at < 0 ? controller.text.length : at);
    setState(() {
      _reset();
      _focusLine = index + 1;
    });
  }

  /// One paragraph's field, wherever it is drawn — body text or a table cell.
  Widget _paragraph(int index, List<String> lines) {
    final text = index < lines.length ? lines[index] : '';
    final controller = _controllerFor(index, text);
    final format = _formatFor(index);
    final field = _Paragraph(
      format: format,
      controller: controller,
      focusNode: _focusFor(index),
      onChanged: (value) =>
          ref.read(officeDocProvider.notifier).editLine(index, value),
      // No splitting inside a cell: a new paragraph there would have no format
      // entry, so the grouping that draws the table would lose track of it. Body
      // text has no such constraint.
      onSplit: format.inTable ? null : () => _split(index, controller),
    );
    if (!format.inTable) return field;
    // In a cell the height has to be right, and a `TextField` will not say what
    // its height is: inside the `IntrinsicHeight` a table row needs, it reports
    // the height of one line in the *theme's* text style rather than in the one
    // it is given — 6px short of the truth here, which is what struck a
    // "BOTTOM OVERFLOWED BY 6.0 PIXELS" stripe across every row.
    //
    // So a `Text` of the same words in the same style is laid *under* the field
    // to set the size, and the field fills it. The Text is the measurer; the
    // field is what you type in.
    return _SizedByText(text: text, format: format, child: field);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final rows = editorRows(lines.length, widget.doc.formats);
    if (_focusLine case final line?) {
      // After the frame the new field exists to take it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusFor(line).requestFocus();
        _focusLine = null;
      });
    }
    return ColoredBox(
      color: AppPalette.paperDesk,
      child: Center(
        child: SizedBox(
          width: OfficeEditorView._pageWidth,
          child: ColoredBox(
            color: AppPalette.paper,
            // The page's own ink, so nothing on it can inherit the app's — see the
            // token's note. A document is white paper in both themes.
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: AppPalette.paperInk),
              child: Theme(
                // A page is not a form: the app's field theme would fill every
                // paragraph with a grey rounded box.
                data: Theme.of(context).copyWith(
                  inputDecorationTheme: const InputDecorationTheme(),
                  textSelectionTheme: TextSelectionThemeData(
                    cursorColor: AppPalette.accent,
                    selectionColor: AppPalette.accent.withValues(alpha: 0.22),
                    selectionHandleColor: AppPalette.accent,
                  ),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(72, 56, 72, 72),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => switch (rows[index]) {
                    OfficeEditorParagraph(:final index) => _paragraph(
                      index,
                      lines,
                    ),
                    OfficeEditorTable(:final rows, :final gridTwips) => _Table(
                      rows: rows,
                      gridTwips: gridTwips,
                      // The page's text column, which is what the table has to
                      // fit inside — the padding above is its margins.
                      availableWidth: OfficeEditorView._pageWidth - 144,
                      cell: (line) => _paragraph(line, lines),
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One paragraph: its own spacing, its own indents, its own caret.
class _Paragraph extends StatelessWidget {
  const _Paragraph({
    required this.format,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.onSplit,
  });

  final DocxLineFormat format;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// What Enter does — null where a paragraph may not be split (a table cell).
  final VoidCallback? onSplit;

  /// [field], with Enter starting a new paragraph where that is allowed.
  Widget _withEnter(Widget field) {
    final split = onSplit;
    if (split == null) return field;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): split,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): split,
      },
      child: field,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: AppPalette.paperInk,
      fontSize: format.fontSizePx,
      fontWeight: format.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: format.italic ? FontStyle.italic : FontStyle.normal,
      decoration: format.underline ? TextDecoration.underline : null,
      fontFamily: format.fontFamily,
      height: format.lineHeight,
    );
    if (format.hasPicture) return _PicturePlaceholder(format: format);
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      // Wraps like a paragraph; Enter is intercepted below so it starts a new
      // paragraph instead of a line inside this one.
      maxLines: null,
      style: style,
      textAlign: switch (format.align) {
        DocxTextAlign.center => TextAlign.center,
        DocxTextAlign.right => TextAlign.right,
        DocxTextAlign.justify => TextAlign.justify,
        DocxTextAlign.left => TextAlign.left,
      },
      decoration: const InputDecoration(
        border: InputBorder.none,
        filled: false,
        isCollapsed: true,
        contentPadding: EdgeInsets.zero,
        // A paragraph with no text is a blank line in the document, not an
        // invitation — so no hint sits in it.
        hintText: null,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(
        top: format.spaceBeforePx,
        bottom: format.spaceAfterPx,
        left: format.indentLeftPx,
        right: format.indentRightPx,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A first-line indent, as the empty box it is. A hang (negative) is
          // where a list marker would sit; the Edit view has no markers, so it
          // simply doesn't indent.
          if (format.firstLinePx > 0) SizedBox(width: format.firstLinePx),
          Expanded(child: _withEnter(field)),
        ],
      ),
    );
  }
}

/// A table, as a grid with a caret in every cell.
///
/// Rows of sized boxes rather than Flutter's `Table`, for the reason a Word table
/// forces: `w:gridSpan`. Word merges cells constantly — a heading across three
/// columns — and `Table` has no colspan at all, so a table built with it puts the
/// wrong text under the wrong heading. Here a spanning cell is simply a box as
/// wide as the columns it covers, which the grid already says.
class _Table extends StatelessWidget {
  const _Table({
    required this.rows,
    required this.gridTwips,
    required this.availableWidth,
    required this.cell,
  });

  final List<List<OfficeEditorCell>> rows;
  final List<int> gridTwips;
  final double availableWidth;

  /// Builds the field for one line — the same paragraph widget body text uses, so
  /// a cell is typed in exactly like anything else.
  final Widget Function(int line) cell;

  /// Word's hairline, and the app's own [AppPalette.divider] deliberately not
  /// used: the grid is part of the document, so it stays the same in both themes.
  static const _rule = Color(0xFF9A9A9A);

  @override
  Widget build(BuildContext context) {
    final widths = _columnWidths();
    if (widths.isEmpty || rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      // Word's own air around a table; without it a table butts against the
      // paragraphs either side.
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            IntrinsicHeight(
              // What makes a row's borders line up: without it every cell is as
              // tall as its own text and the frame comes out ragged.
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final box in row)
                    Container(
                      width: _widthOf(box, widths),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: _rule, width: 0.7),
                          left: BorderSide(color: _rule, width: 0.7),
                          bottom: BorderSide(color: _rule, width: 0.7),
                          right: BorderSide(color: _rule, width: 0.7),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [for (final line in box.lines) cell(line)],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  double _widthOf(OfficeEditorCell box, List<double> widths) {
    var width = 0.0;
    for (var i = 0; i < box.gridSpan; i++) {
      final column = box.column + i;
      if (column < widths.length) width += widths[column];
    }
    // A cell whose columns the grid doesn't describe still needs a width to draw
    // in, or the row collapses around it.
    return width > 0 ? width : availableWidth / widths.length;
  }

  /// The grid, scaled to fit the page's text column.
  ///
  /// A table wider than the page is scaled down rather than clipped — Word would
  /// have laid it out to fit, and a table with its last column off the paper is
  /// unreadable. A missing `w:tblGrid` falls back to equal columns, which happens
  /// in files that have been through a converter.
  List<double> _columnWidths() {
    final grid = gridTwips.where((w) => w > 0).toList();
    if (grid.isEmpty) {
      final columns = rows.first.length;
      if (columns == 0) return const [];
      return List.filled(columns, availableWidth / columns);
    }
    final natural = grid.fold<int>(0, (sum, w) => sum + w) / 15;
    final scale = natural > availableWidth ? availableWidth / natural : 1.0;
    return [for (final w in grid) (w / 15) * scale];
  }
}

/// Where a picture is, in a view that cannot draw one.
///
/// Says which view can, rather than leaving a gap: the paragraph is still there
/// and still saves — this only stands in for what it holds.
class _PicturePlaceholder extends StatelessWidget {
  const _PicturePlaceholder({required this.format});

  final DocxLineFormat format;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      top: format.spaceBeforePx + 4,
      bottom: format.spaceAfterPx + 4,
      left: format.indentLeftPx,
      right: format.indentRightPx,
    ),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x33000000)),
        color: const Color(0x08000000),
      ),
      child: const Text(
        'Picture — switch to Read to see it',
        style: TextStyle(fontSize: 11.5, color: Color(0x99000000)),
      ),
    ),
  );
}

/// An editable paragraph whose height comes from a `Text`, not from the field.
///
/// The trick a table row forces (see `_paragraph`): `IntrinsicHeight` asks its
/// children how tall they want to be, and `TextField` answers with one line of the
/// ambient style instead of the style it was handed — short, and short by a
/// different amount per paragraph. A `Text` of the same string in the same style
/// answers correctly, wrapping and all, so it goes underneath to set the size and
/// the field is stretched over it.
///
/// The Text is invisible, not absent: it has to be laid out to measure, and it has
/// to be the thing the parent sizes to.
class _SizedByText extends StatelessWidget {
  const _SizedByText({
    required this.text,
    required this.format,
    required this.child,
  });

  final String text;
  final DocxLineFormat format;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // A space for an empty paragraph: an empty string measures zero tall, and a
      // cell with no text still has a line's height in Word.
      Opacity(
        opacity: 0,
        child: Text(
          text.isEmpty ? ' ' : text,
          style: TextStyle(
            fontSize: format.fontSizePx,
            fontWeight: format.bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: format.italic ? FontStyle.italic : FontStyle.normal,
            fontFamily: format.fontFamily,
            height: format.lineHeight,
          ),
          textAlign: switch (format.align) {
            DocxTextAlign.center => TextAlign.center,
            DocxTextAlign.right => TextAlign.right,
            DocxTextAlign.justify => TextAlign.justify,
            DocxTextAlign.left => TextAlign.left,
          },
        ),
      ),
      Positioned.fill(child: child),
    ],
  );
}
