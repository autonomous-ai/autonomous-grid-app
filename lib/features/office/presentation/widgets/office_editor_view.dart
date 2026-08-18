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
/// a heading looks like a heading, a centred line stays centred and a numbered
/// item keeps its number. It is not Word: no page breaks, no headers or footers,
/// and a heading whose style is based on another heading draws at the body size.
///
/// Tables are drawn as tables and their cells can be typed in (see
/// `office_editor_rows.dart` for how the flat paragraph list is grouped back into
/// a grid). Pictures are drawn at the size Word was told to draw them; one whose
/// bytes are missing from the file leaves a frame rather than a gap, because the
/// author put something there.
class OfficeEditorView extends ConsumerStatefulWidget {
  const OfficeEditorView({super.key, required this.doc});

  final OfficeDocOpen doc;

  /// The page's own margins at full width. Word's inch, and the most the page
  /// gives up — a narrow pane gets a proportional share instead, or the margins
  /// alone would be wider than the paper.
  static const _pageInset = 72.0;

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

  List<String> get _lines => widget.doc.lines;

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
  ///
  /// [width] is the line it has to fit in, and it is *passed*, not measured: a
  /// `LayoutBuilder` here sat inside the `IntrinsicHeight` a table row needs, and
  /// intrinsics cannot run a layout callback — Flutter answers that by mutating
  /// the render tree mid-pass, which surfaced as a mouse-tracker assertion
  /// (`!_debugDuringDeviceUpdate`). Every caller already knows the width.
  Widget _paragraph(int index, List<String> lines, double width) {
    final text = index < lines.length ? lines[index] : '';
    final controller = _controllerFor(index, text);
    final format = _formatFor(index);
    return _Paragraph(
      format: format,
      controller: controller,
      focusNode: _focusFor(index),
      text: text,
      onChanged: (value) =>
          ref.read(officeDocProvider.notifier).editLine(index, value),
      // No splitting inside a cell: a new paragraph there would have no format
      // entry, so the grouping that draws the table would lose track of it. Body
      // text has no such constraint.
      onSplit: format.inTable ? null : () => _split(index, controller),
      width: width,
    );
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The document's own paper — A4 is 794px where US Letter is 816, and a
          // document laid out for one reads wrong at the other's measure. Never
          // wider than the pane, though: a fixed page is what overflowed every
          // table the moment the window came off full screen.
          final paper = widget.doc.pageWidthPx;
          final page = constraints.maxWidth < paper
              ? constraints.maxWidth
              : paper;
          // Margins shrink with the page rather than holding their inch: at the
          // app's narrowest window two 72px margins are wider than the paper
          // between them, and the text would be laid out in nothing.
          final inset = (page * 0.09).clamp(16.0, OfficeEditorView._pageInset);
          // What is left for text — and what a table must fit inside. Derived,
          // never assumed: a table sized to a constant overflowed by exactly the
          // width the window had lost.
          final column = page - inset * 2;
          return Center(
            child: SizedBox(
              width: page,
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
                        selectionColor: AppPalette.accent.withValues(
                          alpha: 0.22,
                        ),
                        selectionHandleColor: AppPalette.accent,
                      ),
                    ),
                    child: ListView.builder(
                      // The *same* [inset] the column above was derived from.
                      // These two are one measurement: while this held the full
                      // 72px and the column shrank with the page, every table
                      // was told it had `144 - 2 * inset` more room than the
                      // list would give it — 45px at a 550px page, which is
                      // exactly what overflowed.
                      padding: EdgeInsets.fromLTRB(inset, 56, inset, 72),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => switch (rows[index]) {
                        OfficeEditorParagraph(:final index) => _paragraph(
                          index,
                          lines,
                          column,
                        ),
                        OfficeEditorTable(:final rows, :final gridTwips) =>
                          _Table(
                            rows: rows,
                            gridTwips: gridTwips,
                            // The real column, measured this frame — a table
                            // sized to a constant overflowed by exactly the
                            // width the window had lost.
                            availableWidth: column,
                            cell: (line, width) =>
                                _paragraph(line, lines, width),
                          ),
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
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
    required this.text,
    required this.width,
    required this.onChanged,
    this.onSplit,
  });

  final DocxLineFormat format;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// The paragraph's text, for measuring — see [_SizedByText].
  final String text;

  /// The width of the line this paragraph is drawn on — see the note on
  /// `_OfficeEditorViewState._paragraph` for why it is passed rather than
  /// measured here.
  final double width;

  final ValueChanged<String> onChanged;

  /// What Enter does — null where a paragraph may not be split (a table cell).
  final VoidCallback? onSplit;

  /// The most of a line that indents, markers and margins may take between them.
  ///
  /// A ceiling, not a target: it only ever bites in a column too narrow for the
  /// document's own geometry, where the choice is between text with nowhere to go
  /// and an indent that isn't quite right.
  static const _maxLeadShare = 0.6;

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
    if (format.picture case final picture?) {
      return _Picture(picture: picture, format: format);
    }
    final textAlign = switch (format.align) {
      DocxTextAlign.center => TextAlign.center,
      DocxTextAlign.right => TextAlign.right,
      DocxTextAlign.justify => TextAlign.justify,
      DocxTextAlign.left => TextAlign.left,
    };
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      // Wraps like a paragraph; Enter is intercepted below so it starts a new
      // paragraph instead of a line inside this one.
      maxLines: null,
      style: style,
      textAlign: textAlign,
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
    // A hang is the room the list marker sits in, so the row starts that far to
    // the left of the text and the marker box takes it back. Word's geometry:
    // text at indentLeft, marker at indentLeft + firstLine.
    final hang = format.marker == null || format.firstLinePx >= 0
        ? 0.0
        : -format.firstLinePx;
    // Indents are absolute where columns are not: a paragraph indented half an
    // inch inside a 40px table cell asks for more furniture than the cell has,
    // and fixed boxes in a `Row` do not give way — they overflow. Everything
    // before the text is capped at [_maxLeadShare] of the line so the text always
    // has a line to be on.
    final room = width > 0 ? width : 0.0;
    final lead = (format.indentLeftPx - hang).clamp(0.0, room * _maxLeadShare);
    final marker = format.marker;
    final markerWidth = marker == null
        ? 0.0
        : (hang > 0 ? hang : 24.0).clamp(0.0, room * _maxLeadShare - lead);
    final firstLine = marker != null || format.firstLinePx <= 0
        ? 0.0
        : format.firstLinePx.clamp(0.0, room * _maxLeadShare - lead);
    return Padding(
      padding: EdgeInsets.only(
        top: format.spaceBeforePx,
        bottom: format.spaceAfterPx,
        left: lead,
        right: format.indentRightPx.clamp(0.0, room * _maxLeadShare),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The number or bullet, drawn *beside* the field and never inside it:
          // it is not part of the paragraph's text (Word generates it from
          // `numbering.xml`), so it must not be typeable and must never be
          // written back. See `docx_numbering.dart`.
          if (marker != null)
            SizedBox(
              width: markerWidth,
              child: Text(marker, style: style),
            ),
          // A first-line indent, as the empty box it is.
          if (firstLine > 0) SizedBox(width: firstLine),
          // In a table the height has to be exact, and a `TextField` will not say
          // what its height is: inside the `IntrinsicHeight` a row needs, it
          // reports one line of the *theme's* text style instead of the style it
          // was given. So a `Text` of the same words measures it.
          //
          // It wraps the field and nothing else. Wrapping the whole paragraph —
          // padding, marker and all — is what struck "RenderFlex overflowed by 45
          // pixels": the measuring `Text` knew nothing about the indent, so the
          // row was forced into a box narrower than its own indent.
          Expanded(
            child: format.inTable
                ? _SizedByText(
                    text: text,
                    style: style,
                    align: textAlign,
                    child: _withEnter(field),
                  )
                : _withEnter(field),
          ),
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
  ///
  /// Handed the width it has to draw in, because the paragraph no longer measures
  /// for itself: a `LayoutBuilder` inside this table's `IntrinsicHeight` is what
  /// the mouse-tracker assertion was.
  final Widget Function(int line, double width) cell;

  /// Word's hairline, and the app's own [AppPalette.divider] deliberately not
  /// used: the grid is part of the document, so it stays the same in both themes.
  static const _rule = Color(0xFF9A9A9A);

  /// The air between a cell's rule and its text, each side.
  static const _cellPad = 7.0;

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
                        horizontal: _cellPad,
                        vertical: 3,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final line in box.lines)
                            // What is left of the cell once its own padding has
                            // had its share — the line the text really gets.
                            cell(line, _widthOf(box, widths) - _cellPad * 2),
                        ],
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

/// A picture in the document, drawn where its paragraph is.
///
/// Read-only, like the picture itself: there is nothing to type into. The
/// paragraph is still a paragraph and still saves — a save doesn't touch a
/// paragraph whose text didn't change, so the drawing inside it is never at risk
/// from being shown here.
class _Picture extends StatelessWidget {
  const _Picture({required this.picture, required this.format});

  final DocxPicture picture;
  final DocxLineFormat format;

  @override
  Widget build(BuildContext context) {
    final bytes = picture.bytes;
    return Padding(
      padding: EdgeInsets.only(
        top: format.spaceBeforePx + 4,
        bottom: format.spaceAfterPx + 4,
        left: format.indentLeftPx,
        right: format.indentRightPx,
      ),
      child: Align(
        alignment: switch (format.align) {
          DocxTextAlign.center => Alignment.center,
          DocxTextAlign.right => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: bytes == null
            ? const _MissingPicture()
            : Image.memory(
                bytes,
                width: picture.widthPx,
                height: picture.heightPx,
                // The size Word was told to draw it at is the size it prints at,
                // so a picture too wide for the column is scaled, not cropped.
                fit: BoxFit.contain,
                // A format Flutter can't decode — an EMF or WMF out of an old
                // document — leaves the frame rather than a red exception box, so
                // the text around it is still readable.
                errorBuilder: (context, _, _) => const _MissingPicture(),
              ),
      ),
    );
  }
}

/// A picture the document points at that this build cannot draw.
class _MissingPicture extends StatelessWidget {
  const _MissingPicture();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0x33000000)),
      color: const Color(0x08000000),
    ),
    child: const Text(
      "Picture — Grid can't show this one",
      style: TextStyle(fontSize: 11.5, color: Color(0x99000000)),
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
    required this.style,
    required this.align,
    required this.child,
  });

  final String text;

  /// The very style the field draws in — passed rather than rebuilt, because a
  /// measurer that measures a *different* style is worse than none.
  final TextStyle style;
  final TextAlign align;

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // A space for an empty paragraph: an empty string measures zero tall, and a
      // cell with no text still has a line's height in Word.
      Opacity(
        opacity: 0,
        child: Text(text.isEmpty ? ' ' : text, style: style, textAlign: align),
      ),
      Positioned.fill(child: child),
    ],
  );
}
