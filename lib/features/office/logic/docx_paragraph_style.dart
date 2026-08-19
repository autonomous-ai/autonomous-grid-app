/// What the toolbar changes about a paragraph — and only what the user pressed.
///
/// A **delta, not a snapshot**, and that is the whole design of this file. A
/// paragraph's look comes from a cascade: `docDefaults`, then its named style,
/// then its own `w:pPr`/`w:rPr`. Writing the *resolved* look back would freeze
/// the style's share into the paragraph — a heading that is bold because it is a
/// heading would come back bold because somebody said so, and would stop
/// following its style for good. So every field here is nullable and null means
/// "leave that one to the cascade".
///
/// Units are the file's own — twips for space, half-points for type — because
/// this is what gets written. The pixels the screen works in are a rendering of
/// it ([DocxStyledFormat.withStyle]); rounding through pixels on every press
/// would walk a half-inch indent away from half an inch.
library;

import 'docx_format.dart';

/// The width of one press of Increase indent — Word's default tab, and the step
/// Google Docs moves by, so a document indented in one reads right in the other.
const docxIndentStepTwips = docxTwipsPerInch ~/ 2;

/// The line spacings the toolbar offers, as multiples of single.
///
/// Word writes these as `w:line` in 240ths, so 1.0 is 240 and 1.5 is 360 — the
/// arithmetic is exact at every one of them, which is why the menu offers these
/// and not a free number.
const docxLineSpacings = [1.0, 1.15, 1.5, 2.0];

/// The type sizes the toolbar's box steps through.
///
/// Word's own list. Between two of them the buttons step to the next one up or
/// down rather than by a point, so going from 11 to 12 to 14 takes three presses
/// and not four.
const docxFontSizes = [
  8.0,
  9.0,
  10.0,
  11.0,
  12.0,
  14.0,
  16.0,
  18.0,
  20.0,
  24.0,
  28.0,
  32.0,
  36.0,
  48.0,
  72.0,
];

class DocxParagraphStyle {
  const DocxParagraphStyle({
    this.align,
    this.indentLeftTwips,
    this.indentRightTwips,
    this.firstLineTwips,
    this.lineSpacing,
    this.bold,
    this.italic,
    this.underline,
    this.fontFamily,
    this.fontHalfPoints,
  });

  final DocxTextAlign? align;

  final int? indentLeftTwips;
  final int? indentRightTwips;

  /// Where the first line starts relative to the rest: positive indents it,
  /// negative hangs it. Word writes the two as different attributes
  /// (`w:firstLine` and `w:hanging`) and never both, which the writer handles.
  final int? firstLineTwips;

  /// A multiple of single spacing — see [docxLineSpacings].
  final double? lineSpacing;

  final bool? bold;
  final bool? italic;
  final bool? underline;

  final String? fontFamily;

  /// Half-points, which is how `w:sz` counts: 22 is 11pt.
  final int? fontHalfPoints;

  /// Nothing was pressed — so nothing about this paragraph needs rewriting.
  bool get isEmpty =>
      align == null &&
      indentLeftTwips == null &&
      indentRightTwips == null &&
      firstLineTwips == null &&
      lineSpacing == null &&
      bold == null &&
      italic == null &&
      underline == null &&
      fontFamily == null &&
      fontHalfPoints == null;

  /// [next] laid over this one — what the second press of the toolbar adds to
  /// the first. Whatever [next] states wins; the rest is kept.
  DocxParagraphStyle merge(DocxParagraphStyle next) => DocxParagraphStyle(
    align: next.align ?? align,
    indentLeftTwips: next.indentLeftTwips ?? indentLeftTwips,
    indentRightTwips: next.indentRightTwips ?? indentRightTwips,
    firstLineTwips: next.firstLineTwips ?? firstLineTwips,
    lineSpacing: next.lineSpacing ?? lineSpacing,
    bold: next.bold ?? bold,
    italic: next.italic ?? italic,
    underline: next.underline ?? underline,
    fontFamily: next.fontFamily ?? fontFamily,
    fontHalfPoints: next.fontHalfPoints ?? fontHalfPoints,
  );
}

/// The document's look with a pending change laid over it.
///
/// What keeps the page honest between a press and a save: the editor draws from
/// this, so pressing Centre centres the paragraph on screen at once and the file
/// gets the same instruction when Save runs. Two renderings of one delta, never
/// two decisions.
extension DocxStyledFormat on DocxLineFormat {
  DocxLineFormat withStyle(DocxParagraphStyle? style) {
    if (style == null || style.isEmpty) return this;
    return DocxLineFormat(
      align: style.align ?? align,
      fontSizePx: style.fontHalfPoints == null
          ? fontSizePx
          : docxPxOfHalfPoints(style.fontHalfPoints!),
      bold: style.bold ?? bold,
      italic: style.italic ?? italic,
      underline: style.underline ?? underline,
      // `w:line` in 240ths is single spacing, and single is approximated at 1.2
      // for the reason `docx_format.dart` gives — the face's own line height is
      // never read. The same 1.2 here keeps a paragraph the same height whether
      // its spacing came out of the file or off this toolbar.
      lineHeight: style.lineSpacing == null
          ? lineHeight
          : 1.2 * style.lineSpacing!,
      indentLeftPx: style.indentLeftTwips == null
          ? indentLeftPx
          : docxPxOfTwips(style.indentLeftTwips!),
      indentRightPx: style.indentRightTwips == null
          ? indentRightPx
          : docxPxOfTwips(style.indentRightTwips!),
      firstLinePx: style.firstLineTwips == null
          ? firstLinePx
          : docxPxOfTwips(style.firstLineTwips!),
      spaceBeforePx: spaceBeforePx,
      spaceAfterPx: spaceAfterPx,
      fontFamily: style.fontFamily ?? fontFamily,
      table: table,
      picture: picture,
      marker: marker,
    );
  }
}
