/// Just enough of a paragraph's formatting to type into it.
///
/// The Read view is the faithful one — `docx_file_viewer` resolves the whole
/// styles.xml cascade, numbering, tables and pictures. This is for the Edit view,
/// where the job is different: the caret has to sit in text that *looks* like the
/// document, and it has to do so on exactly the paragraphs `docx_edit.dart` can
/// patch. So this reads the same `<w:p>` list that file walks, and reads it in the
/// same pass — an editor whose formatting came from a second, independent parse
/// would be one document-shaped disagreement away from writing a paragraph's text
/// into its neighbour.
///
/// **Deliberately shallow.** Direct `w:pPr`/`w:rPr`, the paragraph's own style one
/// level deep, then `w:docDefaults`. No `w:basedOn` chain, no theme fonts, no
/// numbering — a heading based on another heading shows the body size here while
/// the Read view has it right. That is the honest trade for an edit surface: it
/// has to be recognisable, not exact.
library;

import 'package:xml/xml.dart';

/// How a paragraph's lines sit against the column.
enum DocxTextAlign { left, center, right, justify }

/// Where a paragraph sits inside a table.
///
/// Carried per paragraph rather than as a tree, because the flat paragraph list
/// is what the save patches by: the Edit view groups consecutive paragraphs that
/// share a [table] back into a grid to draw, and every cell it draws still knows
/// the one index that writes it back.
class DocxTableSpan {
  const DocxTableSpan({
    required this.table,
    required this.row,
    required this.column,
    required this.gridSpan,
    required this.gridTwips,
  });

  /// Which table in the document — its position among all of them, so two
  /// tables in a row can't be grouped into one.
  final int table;

  final int row;

  /// The first grid column this cell covers.
  final int column;

  /// How many grid columns it covers (`w:gridSpan`).
  final int gridSpan;

  /// The table's column widths (`w:tblGrid`), shared by every cell of it.
  final List<int> gridTwips;
}

/// What the Edit view needs to draw one paragraph.
class DocxLineFormat {
  const DocxLineFormat({
    this.align = DocxTextAlign.left,
    this.fontSizePx = 14.67,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.lineHeight = 1.2,
    this.indentLeftPx = 0,
    this.indentRightPx = 0,
    this.firstLinePx = 0,
    this.spaceBeforePx = 0,
    this.spaceAfterPx = 0,
    this.fontFamily,
    this.table,
    this.hasPicture = false,
  });

  /// Word's default: 11pt, which is 14.67 logical pixels at 96dpi.
  static const fallback = DocxLineFormat();

  final DocxTextAlign align;
  final double fontSizePx;
  final bool bold;
  final bool italic;
  final bool underline;

  /// A multiple of the font size — what `TextStyle.height` takes.
  final double lineHeight;

  final double indentLeftPx;
  final double indentRightPx;

  /// Positive indents the first line, negative hangs it.
  final double firstLinePx;

  final double spaceBeforePx;
  final double spaceAfterPx;
  final String? fontFamily;

  /// Where this paragraph sits in a table, or null for body text.
  final DocxTableSpan? table;

  /// The paragraph holds a drawing. The Edit view can't draw pictures, so it says
  /// so with a placeholder instead of leaving an empty gap where one is — a
  /// document that looks like it lost an image is worse than one that says the
  /// image is elsewhere.
  final bool hasPicture;

  bool get inTable => table != null;
}

/// Twips (1/1440 inch) to logical pixels (1/96 inch).
double _px(num twips) => twips / 15;

/// Half-points to logical pixels: a point is 4/3 of a pixel at 96dpi.
double _sizePx(num halfPoints) => halfPoints * 2 / 3;

/// The formatting of each paragraph in [paragraphs], in the same order.
///
/// [stylesRoot] is the root of `word/styles.xml`, or null for a document that has
/// none — the one thing a caller needs to hand over, so how a style is read stays
/// in here.
List<DocxLineFormat> lineFormats(
  List<XmlElement> paragraphs,
  XmlElement? stylesRoot,
  XmlDocument body,
) {
  final styles = _parseStyleTable(stylesRoot);
  final defaults = _parseDefaults(stylesRoot);
  final tables = _tableSpans(body);
  return [
    for (final paragraph in paragraphs)
      _formatOf(paragraph, styles, defaults, tables[paragraph]),
  ];
}

/// Every table's cells, mapped from the paragraphs inside them.
///
/// Keyed by the paragraph element itself — identity, which is exactly right:
/// the caller hands over the same objects, and no two paragraphs are equal
/// without being the same one.
Map<XmlElement, DocxTableSpan> _tableSpans(XmlDocument body) {
  final spans = <XmlElement, DocxTableSpan>{};
  var index = 0;
  for (final table in body.findAllElements('tbl', namespaceUri: '*')) {
    final grid = [
      for (final column in _children(_child(table, 'tblGrid'), 'gridCol'))
        _intAttr(column, 'w') ?? 0,
    ];
    var row = 0;
    for (final tr in _children(table, 'tr')) {
      var column = 0;
      for (final tc in _children(tr, 'tc')) {
        final span = _intVal(_child(tc, 'tcPr'), 'gridSpan') ?? 1;
        for (final paragraph in tc.descendantElements) {
          if (paragraph.name.local != 'p') continue;
          // A nested table's paragraphs belong to *it*, and it gets its own turn
          // in this loop — claiming them here would draw them twice.
          if (spans.containsKey(paragraph)) continue;
          spans[paragraph] = DocxTableSpan(
            table: index,
            row: row,
            column: column,
            gridSpan: span,
            gridTwips: grid,
          );
        }
        column += span;
      }
      row++;
    }
    index++;
  }
  return spans;
}

Iterable<XmlElement> _children(XmlElement? parent, String local) =>
    parent == null
    ? const []
    : parent.childElements.where((c) => c.name.local == local);

DocxLineFormat _formatOf(
  XmlElement paragraph,
  Map<String, _StyleBits> styles,
  _StyleBits defaults,
  DocxTableSpan? table,
) {
  final pPr = _child(paragraph, 'pPr');
  final rPr = _child(pPr, 'rPr') ?? _firstRunProps(paragraph);
  final style = styles[_val(pPr, 'pStyle')] ?? const _StyleBits();
  final spacing = _child(pPr, 'spacing');
  final indent = _child(pPr, 'ind');
  final hanging = _intAttr(indent, 'hanging');
  final size =
      _intVal(rPr, 'sz') ??
      style.sizeHalfPoints ??
      defaults.sizeHalfPoints ??
      22;
  final lineTwips =
      _intAttr(spacing, 'line') ?? style.lineTwips ?? defaults.lineTwips;
  return DocxLineFormat(
    align: _align(_val(pPr, 'jc')) ?? style.align ?? DocxTextAlign.left,
    fontSizePx: _sizePx(size),
    bold: _onOff(rPr, 'b') ?? style.bold ?? defaults.bold ?? false,
    italic: _onOff(rPr, 'i') ?? style.italic ?? defaults.italic ?? false,
    underline: _underline(rPr) ?? style.underline ?? false,
    // `w:line` in the default rule is 240ths of single spacing. Single itself is
    // the font's own line, which this approximates at 1.2 — the Read view is
    // where per-font metrics belong.
    lineHeight: lineTwips == null ? 1.2 : 1.2 * (lineTwips / 240),
    indentLeftPx: _px(
      _intAttr(indent, 'left') ??
          _intAttr(indent, 'start') ??
          style.indentLeftTwips ??
          0,
    ),
    indentRightPx: _px(
      _intAttr(indent, 'right') ?? _intAttr(indent, 'end') ?? 0,
    ),
    firstLinePx: _px(
      hanging != null
          ? -hanging
          : _intAttr(indent, 'firstLine') ?? style.indentFirstLineTwips ?? 0,
    ),
    spaceBeforePx: _px(
      _intAttr(spacing, 'before') ?? style.spaceBeforeTwips ?? 0,
    ),
    spaceAfterPx: _px(_intAttr(spacing, 'after') ?? style.spaceAfterTwips ?? 0),
    fontFamily: _fontOf(rPr) ?? style.font ?? defaults.font,
    table: table,
    hasPicture: _hasPicture(paragraph),
  );
}

/// Whether the paragraph carries a drawing — `w:drawing` for the modern shape,
/// `w:pict` for the VML one older documents still use.
bool _hasPicture(XmlElement paragraph) {
  for (final node in paragraph.descendantElements) {
    if (node.name.local == 'drawing' || node.name.local == 'pict') return true;
  }
  return false;
}

/// The run properties of the paragraph's first run — what the paragraph looks
/// like, when the paragraph mark itself says nothing.
XmlElement? _firstRunProps(XmlElement paragraph) {
  for (final node in paragraph.descendantElements) {
    if (node.name.local == 'r') return _child(node, 'rPr');
  }
  return null;
}

/// The subset of a style definition this view reads.
class _StyleBits {
  const _StyleBits({
    this.sizeHalfPoints,
    this.bold,
    this.italic,
    this.underline,
    this.align,
    this.lineTwips,
    this.spaceBeforeTwips,
    this.spaceAfterTwips,
    this.indentLeftTwips,
    this.indentFirstLineTwips,
    this.font,
  });

  final int? sizeHalfPoints;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final DocxTextAlign? align;
  final int? lineTwips;
  final int? spaceBeforeTwips;
  final int? spaceAfterTwips;
  final int? indentLeftTwips;
  final int? indentFirstLineTwips;
  final String? font;
}

/// styleId → the bits of it this view uses.
Map<String, _StyleBits> _parseStyleTable(XmlElement? stylesRoot) {
  if (stylesRoot == null) return const {};
  final table = <String, _StyleBits>{};
  for (final style in stylesRoot.childElements) {
    if (style.name.local != 'style') continue;
    final id = _attr(style, 'styleId');
    if (id == null) continue;
    table[id] = _bitsOf(_child(style, 'pPr'), _child(style, 'rPr'));
  }
  return table;
}

/// `w:docDefaults` — the floor under every paragraph.
_StyleBits _parseDefaults(XmlElement? stylesRoot) {
  final defaults = _child(stylesRoot, 'docDefaults');
  if (defaults == null) return const _StyleBits();
  return _bitsOf(
    _child(_child(defaults, 'pPrDefault'), 'pPr'),
    _child(_child(defaults, 'rPrDefault'), 'rPr'),
  );
}

_StyleBits _bitsOf(XmlElement? pPr, XmlElement? rPr) {
  final spacing = _child(pPr, 'spacing');
  final indent = _child(pPr, 'ind');
  final hanging = _intAttr(indent, 'hanging');
  return _StyleBits(
    sizeHalfPoints: _intVal(rPr, 'sz'),
    bold: _onOff(rPr, 'b'),
    italic: _onOff(rPr, 'i'),
    underline: _underline(rPr),
    align: _align(_val(pPr, 'jc')),
    lineTwips: _intAttr(spacing, 'line'),
    spaceBeforeTwips: _intAttr(spacing, 'before'),
    spaceAfterTwips: _intAttr(spacing, 'after'),
    indentLeftTwips: _intAttr(indent, 'left') ?? _intAttr(indent, 'start'),
    indentFirstLineTwips: hanging != null
        ? -hanging
        : _intAttr(indent, 'firstLine'),
    font: _fontOf(rPr),
  );
}

String? _fontOf(XmlElement? rPr) {
  final fonts = _child(rPr, 'rFonts');
  if (fonts == null) return null;
  for (final slot in ['ascii', 'hAnsi', 'eastAsia']) {
    final name = _attr(fonts, slot);
    if (name != null && name.trim().isNotEmpty) return name.trim();
  }
  return null;
}

DocxTextAlign? _align(String? raw) => switch (raw?.trim()) {
  'center' => DocxTextAlign.center,
  'right' || 'end' => DocxTextAlign.right,
  'both' || 'justify' || 'distribute' => DocxTextAlign.justify,
  'left' || 'start' => DocxTextAlign.left,
  _ => null,
};

XmlElement? _child(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final child in parent.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

String? _attr(XmlElement? element, String local) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.name.local == local) return attribute.value;
  }
  return null;
}

String? _val(XmlElement? parent, String local) =>
    _attr(_child(parent, local), 'val');

int? _intAttr(XmlElement? element, String local) =>
    int.tryParse(_attr(element, local)?.trim() ?? '');

int? _intVal(XmlElement? parent, String local) =>
    int.tryParse(_val(parent, local)?.trim() ?? '');

/// An OOXML on/off property: present with no value is **on**, `0`/`false`/`off`
/// is a real off, absent is neither.
bool? _onOff(XmlElement? parent, String local) {
  final element = _child(parent, local);
  if (element == null) return null;
  final raw = _attr(element, 'val');
  if (raw == null) return true;
  return switch (raw.trim().toLowerCase()) {
    '0' || 'false' || 'off' => false,
    _ => true,
  };
}

bool? _underline(XmlElement? rPr) {
  final value = _val(rPr, 'u');
  if (value == null) return null;
  return value.trim().toLowerCase() != 'none';
}
