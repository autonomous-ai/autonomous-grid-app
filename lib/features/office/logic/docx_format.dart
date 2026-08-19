/// Just enough of a paragraph's formatting to type into it.
///
/// The caret has to sit in text that *looks* like the document, and it has to do
/// so on exactly the paragraphs `docx_edit.dart` can patch. So this reads the same
/// `<w:p>` list that file walks, and reads it in the same pass — an editor whose
/// formatting came from a second, independent parse would be one document-shaped
/// disagreement away from writing a paragraph's text into its neighbour.
///
/// **Deliberately shallow.** Direct `w:pPr`/`w:rPr`, the paragraph's own style one
/// level deep, then `w:docDefaults`. No `w:basedOn` chain and no theme fonts — a
/// heading based on another heading shows the body size here. That is the honest
/// trade for an edit surface: it has to be recognisable, not exact.
///
/// Numbering is the exception, and had to be: a list's "1." is not in the
/// document's text at all (see `docx_numbering.dart`), so leaving it out was not
/// approximating a document — it was showing a numbered section with no numbers.
library;

import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'docx_numbering.dart';

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

/// A picture in a paragraph, ready to draw.
class DocxPicture {
  const DocxPicture({this.bytes, this.widthPx, this.heightPx});

  /// The media part's own bytes, straight out of the zip.
  final Uint8List? bytes;

  /// The size Word was told to draw it at, in logical pixels.
  final double? widthPx;
  final double? heightPx;

  /// The document points at a picture this build cannot produce — the part is
  /// missing from the zip. Worth drawing a frame for rather than nothing: the
  /// author put something here.
  bool get broken => bytes == null;
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
    this.picture,
    this.marker,
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

  /// The picture this paragraph holds, with the bytes to draw it. Null for a
  /// paragraph that holds none — and also for one whose picture this build can't
  /// reach, which [DocxPicture.broken] tells apart.
  final DocxPicture? picture;

  /// The number or bullet Word draws beside this paragraph, or null when it
  /// draws none.
  ///
  /// Not part of the paragraph's text and never written back — see
  /// `docx_numbering.dart`. The view draws it in the hanging indent, beside the
  /// field rather than in it.
  final String? marker;

  bool get inTable => table != null;

  bool get hasPicture => picture != null;
}

/// Twips (1/1440 inch) to logical pixels (1/96 inch).
///
/// Public because the toolbar and the ruler work the same sum backwards — a
/// dragged indent marker is pixels that have to become twips before they are
/// written. Two copies of a conversion are two chances to disagree about what
/// half an inch is.
double docxPxOfTwips(num twips) => twips / 15;

/// How many twips [px] logical pixels are — the inverse of [docxPxOfTwips].
int docxTwipsOfPx(double px) => (px * 15).round();

/// One inch, in twips. Word's own unit for a page margin, a tab stop and the
/// step the indent buttons move by.
const docxTwipsPerInch = 1440;

/// Half-points to logical pixels: a point is 4/3 of a pixel at 96dpi.
double docxPxOfHalfPoints(num halfPoints) => halfPoints * 2 / 3;

/// Points — what a person calls a type size, and what the toolbar shows — from
/// the half-points `w:sz` counts in.
double docxPointsOfHalfPoints(num halfPoints) => halfPoints / 2;

/// Half-points from points, for writing a chosen size back.
int docxHalfPointsOfPoints(double points) => (points * 2).round();

/// The formatting of each paragraph in [paragraphs], in the same order.
///
/// [stylesRoot] is the root of `word/styles.xml`, or null for a document that has
/// none — the one thing a caller needs to hand over, so how a style is read stays
/// in here.
List<DocxLineFormat> lineFormats(
  List<XmlElement> paragraphs,
  XmlElement? stylesRoot,
  XmlDocument body, {
  Map<String, Uint8List> media = const {},
  XmlElement? numberingRoot,
}) {
  final styles = _parseStyleTable(stylesRoot);
  final defaults = _parseDefaults(stylesRoot);
  final tables = _tableSpans(body);
  final numbering = parseNumbering(numberingRoot);
  // Which list each paragraph is in, then the markers in one walk: the third
  // item's "3." depends on the two before it, so this cannot be decided one
  // paragraph at a time.
  final refs = [
    for (final paragraph in paragraphs) _listRefOf(paragraph, styles),
  ];
  final markers = listMarkers(refs, numbering);
  return [
    for (var i = 0; i < paragraphs.length; i++)
      _formatOf(
        paragraphs[i],
        styles,
        defaults,
        tables[paragraphs[i]],
        media,
        marker: markers[i],
        list: refs[i],
        numbering: numbering,
      ),
  ];
}

/// Which list a paragraph belongs to — its own `w:numPr`, else its style's.
///
/// `numId="0"` is Word's way of saying *not* a list: a paragraph turning its
/// style's numbering off. Read as a list, it draws a marker nobody asked for.
DocxListRef? _listRefOf(XmlElement paragraph, Map<String, _StyleBits> styles) {
  final pPr = _child(paragraph, 'pPr');
  final numPr = _child(pPr, 'numPr');
  final own = _val(numPr, 'numId');
  if (own == '0') return null;
  if (own != null) return (numId: own, ilvl: _intVal(numPr, 'ilvl') ?? 0);
  return styles[_val(pPr, 'pStyle')]?.list;
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
  Map<String, Uint8List> media, {
  String? marker,
  DocxListRef? list,
  Map<String, Map<int, DocxNumLevel>> numbering = const {},
}) {
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
  // Where the first line starts, positive to indent and negative to hang. A list
  // level's own hang is the room its marker sits in, and it applies only when the
  // paragraph states no indent of its own — Word merges these per property, it
  // never adds them.
  final levelHang = hangingOf(list, numbering);
  final firstLineTwips = hanging != null
      ? -hanging
      : _intAttr(indent, 'firstLine') ??
            (levelHang != null ? -levelHang : style.indentFirstLineTwips ?? 0);
  return DocxLineFormat(
    align: _align(_val(pPr, 'jc')) ?? style.align ?? DocxTextAlign.left,
    fontSizePx: docxPxOfHalfPoints(size),
    bold: _onOff(rPr, 'b') ?? style.bold ?? defaults.bold ?? false,
    italic: _onOff(rPr, 'i') ?? style.italic ?? defaults.italic ?? false,
    underline: _underline(rPr) ?? style.underline ?? false,
    // `w:line` in the default rule is 240ths of single spacing. Single itself is
    // the font's own line height, which this approximates at 1.2 rather than
    // measuring the face — a per-font table (Arial 1.15, Calibri 1.22, …) is what
    // it would take to match Word's line rhythm exactly.
    lineHeight: lineTwips == null ? 1.2 : 1.2 * (lineTwips / 240),
    indentLeftPx: docxPxOfTwips(
      _intAttr(indent, 'left') ??
          _intAttr(indent, 'start') ??
          indentOf(list, numbering) ??
          style.indentLeftTwips ??
          0,
    ),
    indentRightPx: docxPxOfTwips(
      _intAttr(indent, 'right') ?? _intAttr(indent, 'end') ?? 0,
    ),
    firstLinePx: docxPxOfTwips(firstLineTwips),
    spaceBeforePx: docxPxOfTwips(
      _intAttr(spacing, 'before') ?? style.spaceBeforeTwips ?? 0,
    ),
    spaceAfterPx: docxPxOfTwips(
      _intAttr(spacing, 'after') ?? style.spaceAfterTwips ?? 0,
    ),
    fontFamily: _fontOf(rPr) ?? style.font ?? defaults.font,
    table: table,
    picture: _pictureOf(paragraph, media),
    marker: marker,
  );
}

/// The picture a paragraph carries, if it carries one.
///
/// `w:drawing` is the modern shape and `w:pict` the VML one older documents
/// still use; a paragraph with either is a paragraph the Edit view must draw
/// something for. Which bytes it is comes from the relationship id on the blip,
/// looked up in [media] — a picture whose part is missing from the zip (a broken
/// relationship, which converters leave behind) comes back [DocxPicture.broken]
/// so the view can say so instead of drawing a gap.
DocxPicture? _pictureOf(XmlElement paragraph, Map<String, Uint8List> media) {
  XmlElement? drawing;
  for (final node in paragraph.descendantElements) {
    if (node.name.local == 'drawing' || node.name.local == 'pict') {
      drawing = node;
      break;
    }
  }
  if (drawing == null) return null;
  String? embed;
  double? width;
  double? height;
  for (final node in drawing.descendantElements) {
    switch (node.name.local) {
      case 'blip':
        embed ??= _attr(node, 'embed');
      case 'extent':
        // `wp:extent` is in EMU — 914400 to the inch, so 9525 to a pixel.
        width ??= (_intAttr(node, 'cx') ?? 0) / 9525;
        height ??= (_intAttr(node, 'cy') ?? 0) / 9525;
    }
  }
  final bytes = embed == null ? null : media[embed];
  return DocxPicture(
    bytes: bytes,
    widthPx: (width ?? 0) > 0 ? width : null,
    heightPx: (height ?? 0) > 0 ? height : null,
  );
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
    this.list,
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

  /// A style can carry the list itself (`ListParagraph`, `ListBullet`), which is
  /// how a paragraph gets numbered without a `w:numPr` of its own.
  final DocxListRef? list;
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
  final numPr = _child(pPr, 'numPr');
  final numId = _val(numPr, 'numId');
  return _StyleBits(
    list: numId == null || numId == '0'
        ? null
        : (numId: numId, ilvl: _intVal(numPr, 'ilvl') ?? 0),
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
