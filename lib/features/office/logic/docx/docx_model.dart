/// The document model Docs renders: one block per top-level element of
/// `word/document.xml`, each carrying its own formatting and the index it came
/// from.
///
/// The shape is genoffice's `docx-engine` (`Block` / `Run` / `ParaFormat`), and
/// for its reasons. Two matter here:
///
///  - **A block knows where it came from.** [DocxBlock.docxIndex] is the block's
///    position among the body's top-level children, which is what lets a save
///    rewrite one paragraph and copy every other byte of the file through
///    untouched — the same anchor `docx_edit.dart` patches on.
///  - **Formatting lives on the model, not in the renderer.** Word's cascade
///    (docDefaults → the default style → the named style → direct `pPr`/`rPr`)
///    is resolved once in pure code (`docx_resolve.dart`), so the widgets only
///    draw what they are handed and the rules can be reasoned about without a
///    widget tree.
///
/// Everything here is display data. Lengths keep OOXML's own units — twips for
/// space, half-points for type — and are converted at the edge by
/// [twipsToPx] / [halfPointsToPx], so a rounding choice can't hide in the middle
/// of the model.
library;

import 'dart:typed_data';

/// Word's unit of length: 1/1440 inch. A CSS pixel is 1/96 inch, so a twip is
/// 1/15 of one — the whole conversion.
double twipsToPx(num twips) => twips / 15;

/// Type size: OOXML counts half-points, and a point is 4/3 of a pixel at 96dpi.
double halfPointsToPx(num halfPoints) => halfPoints * 2 / 3;

/// Drawing lengths (`wp:extent`) are in EMU: 914400 to the inch.
double emuToPx(num emu) => emu / 9525;

/// How a paragraph's lines sit against the column.
enum DocxAlign { left, center, right, justify }

/// What `w:spacing w:line` means, because it means three different things.
enum DocxLineRule {
  /// A multiple of single spacing: the value is twips/240 (240 = single).
  auto,

  /// At least this many twips, but a taller font wins.
  atLeast,

  /// Exactly this many twips, whatever the font wants.
  exact,
}

/// A stretch of text and everything Word says about how it looks.
class DocxRun {
  const DocxRun({
    required this.text,
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.color,
    this.sizeHalfPoints,
    this.font,
    this.highlight,
    this.shading,
    this.vertAlign,
    this.styleId,
    this.link,
  });

  /// The run's characters. A `w:tab` arrives as `\t` and a `w:br` as `\n`, so a
  /// renderer that can lay out a string needs nothing else.
  final String text;

  /// Null means "inherit" at every level here — the run said nothing, so the
  /// style or the document default decides. `false` is a real answer (Word's
  /// `w:b w:val="0"` turns bold *off* under a bold style).
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;

  /// Hex without `#`. `auto` is dropped at parse time: it means "let the
  /// renderer choose", which is what null already says.
  final String? color;
  final int? sizeHalfPoints;
  final String? font;

  /// `w:highlight` — a named colour from Word's marker-pen set.
  final String? highlight;

  /// `w:shd w:fill` on the run: hex without `#`. Highlight wins when both are
  /// present, which is Word's own order.
  final String? shading;

  /// Superscript or subscript (`w:vertAlign`).
  final String? vertAlign;

  /// `w:rStyle` — a character style whose own formatting sits under this run's.
  final String? styleId;

  /// Where a hyperlink points, when this run is inside one.
  final String? link;

  bool get isEmpty => text.isEmpty;
}

/// What a paragraph says about itself: `w:pPr`, modelled.
class DocxParaFormat {
  const DocxParaFormat({
    this.align,
    this.lineRule,
    this.lineTwips,
    this.indentLeftTwips,
    this.indentRightTwips,
    this.indentFirstLineTwips,
    this.spaceBeforeTwips,
    this.spaceAfterTwips,
    this.contextualSpacing,
    this.shadingFill,
    this.borders,
    this.pageBreakBefore,
  });

  static const empty = DocxParaFormat();

  final DocxAlign? align;
  final DocxLineRule? lineRule;

  /// The raw `w:line` value in twips. What it means depends on [lineRule] — for
  /// [DocxLineRule.auto] it is 240ths of single spacing.
  final int? lineTwips;

  final int? indentLeftTwips;
  final int? indentRightTwips;

  /// Positive is `w:firstLine`, negative is `w:hanging` — one axis, because they
  /// are the two directions of one thing and Word never has both.
  final int? indentFirstLineTwips;

  final int? spaceBeforeTwips;
  final int? spaceAfterTwips;

  /// `w:contextualSpacing`: drop the space between this paragraph and a
  /// neighbour of the same style. It is why Word lists are tight.
  final bool? contextualSpacing;

  /// Paragraph shading, hex without `#`.
  final String? shadingFill;

  /// Which of the four sides `w:pBdr` draws, as a subset of `tblr`.
  final String? borders;

  final bool? pageBreakBefore;
}

/// A line of a table's or cell's frame.
class DocxBorderSide {
  const DocxBorderSide({required this.widthPx, required this.color});

  /// `w:sz` is in eighths of a point; the parser converts, so this is ready to
  /// draw. Zero means Word said `w:val="none"`.
  final double widthPx;

  /// Hex without `#`.
  final String color;

  bool get visible => widthPx > 0;
}

/// The four sides, any of which may be absent.
class DocxBorders {
  const DocxBorders({this.top, this.left, this.bottom, this.right});

  static const none = DocxBorders();

  final DocxBorderSide? top;
  final DocxBorderSide? left;
  final DocxBorderSide? bottom;
  final DocxBorderSide? right;

  bool get isEmpty =>
      top == null && left == null && bottom == null && right == null;
}

/// One cell, holding blocks rather than text: a cell is a small document, and
/// rendering it with the same code as the body is what keeps a bulleted list
/// inside a cell looking like one.
class DocxTableCell {
  const DocxTableCell({
    required this.blocks,
    this.widthTwips,
    this.gridSpan = 1,
    this.vMergeContinue = false,
    this.shadingFill,
    this.borders,
  });

  final List<DocxBlock> blocks;
  final int? widthTwips;

  /// `w:gridSpan` — how many grid columns this cell covers.
  final int gridSpan;

  /// `w:vMerge` without `w:val="restart"`: this cell is the continuation of the
  /// one above and draws nothing of its own.
  final bool vMergeContinue;

  final String? shadingFill;
  final DocxBorders? borders;
}

/// One row.
class DocxTableRow {
  const DocxTableRow({required this.cells, this.isHeader = false});

  final List<DocxTableCell> cells;

  /// `w:tblHeader` — repeats at the top of every page in Word. Kept because it
  /// also tells the renderer which row a table style's "first row" rules mean.
  final bool isHeader;
}

/// A table: its grid, its rows, and the frame the document or its style asked
/// for.
class DocxTable {
  const DocxTable({
    required this.rows,
    required this.gridTwips,
    this.styleId,
    this.borders,
    this.cellMarginsTwips,
    this.indentTwips,
  });

  final List<DocxTableRow> rows;

  /// `w:tblGrid` — the column widths, which is the only place a table's shape is
  /// stated once for the whole table.
  final List<int> gridTwips;

  final String? styleId;

  /// `w:tblBorders`: the frame every cell inherits unless it overrides it.
  final DocxBorders? borders;

  /// `w:tblCellMar`, in the order top, left, bottom, right.
  final List<int>? cellMarginsTwips;

  final int? indentTwips;
}

/// A picture, with the bytes to draw it.
class DocxImage {
  const DocxImage({
    required this.bytes,
    this.widthPx,
    this.heightPx,
    this.align,
  });

  /// The media part's own bytes, straight out of the zip.
  final Uint8List bytes;

  /// The size Word was told to draw it at (`wp:extent`), already in pixels.
  final double? widthPx;
  final double? heightPx;

  final DocxAlign? align;
}

/// What kind of thing a block is — and therefore how it draws.
enum DocxBlockKind {
  paragraph,
  heading,
  listItem,
  table,
  image,

  /// Something this build does not model (a content control, a chart, a
  /// section break). It keeps its place in the body so indexes stay true, and
  /// draws whatever text it has rather than vanishing.
  passthrough,
}

/// One top-level element of the body.
class DocxBlock {
  const DocxBlock({
    required this.kind,
    required this.docxIndex,
    this.level,
    this.styleId,
    this.list,
    this.format = DocxParaFormat.empty,
    this.runs = const [],
    this.table,
    this.image,
    this.hidden = false,
  });

  final DocxBlockKind kind;

  /// Position among the body's top-level children in the original
  /// `word/document.xml` — the anchor a save patches by. Null for a block that
  /// isn't one of them (a paragraph inside a table cell).
  final int? docxIndex;

  /// Heading level 1–9, when this is a heading.
  final int? level;

  /// `w:pStyle`.
  final String? styleId;

  /// `w:numPr` — which list this item belongs to and how deep.
  final ({String numId, int ilvl})? list;

  final DocxParaFormat format;
  final List<DocxRun> runs;
  final DocxTable? table;
  final DocxImage? image;

  /// Body furniture that is never drawn — the trailing `w:sectPr`, range
  /// markers. Kept in the list so [docxIndex] keeps counting straight.
  final bool hidden;

  /// The block's text, for a preview or a word count.
  String get text => runs.map((r) => r.text).join();
}

/// Formatting a style contributes. The same fields as a run and a paragraph put
/// together, because a paragraph style carries both.
class DocxStyleDisplay {
  const DocxStyleDisplay({
    this.sizeHalfPoints,
    this.color,
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.font,
    this.align,
    this.lineRule,
    this.lineTwips,
    this.spaceBeforeTwips,
    this.spaceAfterTwips,
    this.indentLeftTwips,
    this.indentRightTwips,
    this.indentFirstLineTwips,
    this.contextualSpacing,
  });

  static const empty = DocxStyleDisplay();

  final int? sizeHalfPoints;
  final String? color;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;
  final String? font;
  final DocxAlign? align;
  final DocxLineRule? lineRule;
  final int? lineTwips;
  final int? spaceBeforeTwips;
  final int? spaceAfterTwips;
  final int? indentLeftTwips;
  final int? indentRightTwips;
  final int? indentFirstLineTwips;
  final bool? contextualSpacing;

  /// This style's values with [under] showing through wherever this one is
  /// silent — how a `w:basedOn` chain collapses.
  DocxStyleDisplay over(DocxStyleDisplay under) => DocxStyleDisplay(
    sizeHalfPoints: sizeHalfPoints ?? under.sizeHalfPoints,
    color: color ?? under.color,
    bold: bold ?? under.bold,
    italic: italic ?? under.italic,
    underline: underline ?? under.underline,
    strike: strike ?? under.strike,
    font: font ?? under.font,
    align: align ?? under.align,
    lineRule: lineRule ?? under.lineRule,
    lineTwips: lineTwips ?? under.lineTwips,
    spaceBeforeTwips: spaceBeforeTwips ?? under.spaceBeforeTwips,
    spaceAfterTwips: spaceAfterTwips ?? under.spaceAfterTwips,
    indentLeftTwips: indentLeftTwips ?? under.indentLeftTwips,
    indentRightTwips: indentRightTwips ?? under.indentRightTwips,
    indentFirstLineTwips: indentFirstLineTwips ?? under.indentFirstLineTwips,
    contextualSpacing: contextualSpacing ?? under.contextualSpacing,
  );
}

/// One entry of `word/styles.xml`.
class DocxStyle {
  const DocxStyle({
    required this.styleId,
    required this.type,
    this.name,
    this.basedOn,
    this.headingLevel,
    this.display = DocxStyleDisplay.empty,
    this.list,
    this.isDefault = false,
  });

  final String styleId;

  /// `paragraph`, `character`, `table` or `numbering`.
  final String type;

  final String? name;
  final String? basedOn;
  final int? headingLevel;
  final DocxStyleDisplay display;

  /// A style can carry the list itself (`ListBullet`, `ListNumber`), which is
  /// how a paragraph gets numbered without a `w:numPr` of its own.
  final ({String numId, int ilvl})? list;

  /// `w:default="1"` — Word applies this to every paragraph with no `w:pStyle`.
  final bool isDefault;
}

/// `w:docDefaults` — the floor of the cascade.
class DocxDocDefaults {
  const DocxDocDefaults({
    this.sizeHalfPoints,
    this.font,
    this.color,
    this.bold,
    this.italic,
    this.lineRule,
    this.lineTwips,
    this.spaceBeforeTwips,
    this.spaceAfterTwips,
  });

  static const empty = DocxDocDefaults();

  final int? sizeHalfPoints;
  final String? font;
  final String? color;
  final bool? bold;
  final bool? italic;
  final DocxLineRule? lineRule;
  final int? lineTwips;
  final int? spaceBeforeTwips;
  final int? spaceAfterTwips;
}

/// One level of one list.
class DocxNumLevel {
  const DocxNumLevel({
    required this.numFmt,
    required this.lvlText,
    this.start = 1,
    this.indentLeftTwips,
    this.hangingTwips,
    this.font,
  });

  /// `decimal`, `bullet`, `lowerLetter`, `upperRoman`, …
  final String numFmt;

  /// The marker's template: `%1.`, `%1.%2`, or a literal bullet glyph.
  final String lvlText;

  final int start;

  /// The level's own geometry, used by an item that doesn't state its own.
  final int? indentLeftTwips;

  /// How much room the marker gets — Word's hanging indent.
  final int? hangingTwips;

  /// The marker's font. It matters: Word writes bullets as private-use
  /// characters in Symbol and Wingdings.
  final String? font;
}

/// The page itself.
class DocxSection {
  const DocxSection({
    this.pageWidthTwips = 12240,
    this.pageHeightTwips = 15840,
    this.marginTopTwips = 1440,
    this.marginRightTwips = 1440,
    this.marginBottomTwips = 1440,
    this.marginLeftTwips = 1440,
  });

  /// Defaults are US Letter with inch margins — Word's own, for a document
  /// whose `w:sectPr` says nothing.
  final int pageWidthTwips;
  final int pageHeightTwips;
  final int marginTopTwips;
  final int marginRightTwips;
  final int marginBottomTwips;
  final int marginLeftTwips;

  double get pageWidthPx => twipsToPx(pageWidthTwips);
  double get pageHeightPx => twipsToPx(pageHeightTwips);
  double get marginLeftPx => twipsToPx(marginLeftTwips);
  double get marginRightPx => twipsToPx(marginRightTwips);
  double get marginTopPx => twipsToPx(marginTopTwips);
  double get marginBottomPx => twipsToPx(marginBottomTwips);

  /// The column the text actually runs in.
  double get bodyWidthPx => pageWidthPx - marginLeftPx - marginRightPx;
}

/// A `.docx` read for display: its blocks, and everything the cascade needs to
/// resolve them.
class ParsedDocx {
  const ParsedDocx({
    required this.blocks,
    required this.styles,
    required this.numbering,
    required this.markers,
    this.docDefaults = DocxDocDefaults.empty,
    this.section = const DocxSection(),
    this.themeMinorFont,
    this.themeMajorFont,
  });

  final List<DocxBlock> blocks;

  /// The list marker of each block, by the same index — null where the block
  /// isn't a list item.
  ///
  /// Carried on the document rather than worked out while drawing, because
  /// numbering is a document-wide count: the third item needs to know about the
  /// first two. Computed once, at load, by `listMarkers`.
  final List<String?> markers;

  /// styleId → style, with each `w:basedOn` chain already collapsed into
  /// [DocxStyle.display] so the renderer never walks it.
  final Map<String, DocxStyle> styles;

  /// numId → (ilvl → level).
  final Map<String, Map<int, DocxNumLevel>> numbering;

  final DocxDocDefaults docDefaults;
  final DocxSection section;

  /// The theme's body and heading faces (`a:minorFont` / `a:majorFont`), which
  /// is where a style saying `+minorHAnsi` ends up pointing.
  final String? themeMinorFont;
  final String? themeMajorFont;

  /// The style Word applies to a paragraph with no `w:pStyle` — normally
  /// `Normal`, and part of the document baseline rather than a style anyone
  /// selected.
  DocxStyle? get defaultParagraphStyle {
    for (final style in styles.values) {
      if (style.type == 'paragraph' && style.isDefault) return style;
    }
    return styles['Normal'];
  }
}
