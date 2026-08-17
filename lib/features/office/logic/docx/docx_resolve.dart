/// Word's formatting cascade, resolved into numbers a widget can use.
///
/// Four layers, and the order is the whole point:
///
/// 1. `w:docDefaults` — the document's floor.
/// 2. The default paragraph style (`w:default="1"`, normally `Normal`). Word
///    applies it to every paragraph without a `w:pStyle`, so it is part of the
///    baseline rather than a style anyone picked.
/// 3. The paragraph's own style, its `w:basedOn` chain already collapsed by
///    `docx_parts.dart`.
/// 4. Direct formatting — the `w:pPr` / `w:rPr` on the paragraph and the run.
///
/// Two rules inside that are easy to get wrong and both come from genoffice
/// having measured them against Word:
///
///  - **Undeclared spacing is 0, not a guess.** When neither the default style
///    nor `docDefaults` states `w:spacing`, the answer is zero — a plausible
///    "8pt like Word's UI shows" inflates every paragraph of a document that
///    declares nothing, and table cells worst of all.
///  - **Indents merge per property, they never add.** Direct `w:ind` beats the
///    numbering level's, which beats the style's, one field at a time.
library;

import 'docx_model.dart';
import 'docx_parts.dart';

/// Everything the renderer needs to lay out one paragraph.
class ResolvedPara {
  const ResolvedPara({
    required this.align,
    required this.lineHeight,
    required this.spaceBeforePx,
    required this.spaceAfterPx,
    required this.indentLeftPx,
    required this.indentRightPx,
    required this.firstLinePx,
    required this.base,
    this.shadingFill,
    this.borders,
  });

  final DocxAlign align;

  /// Line height as a multiple of the font size — what `TextStyle.height` takes.
  final double lineHeight;

  final double spaceBeforePx;
  final double spaceAfterPx;
  final double indentLeftPx;
  final double indentRightPx;

  /// Positive indents the first line, negative hangs it — the marker of a list
  /// item sits in that negative space.
  final double firstLinePx;

  /// The run formatting every run in this paragraph starts from.
  final ResolvedRun base;

  final String? shadingFill;
  final String? borders;
}

/// Everything the renderer needs for one run of text.
class ResolvedRun {
  const ResolvedRun({
    required this.fontSizePx,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strike,
    this.colorHex,
    this.fontFamily,
    this.highlight,
    this.shading,
    this.vertAlign,
    this.link,
  });

  final double fontSizePx;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String? colorHex;
  final String? fontFamily;
  final String? highlight;
  final String? shading;
  final String? vertAlign;
  final String? link;

  ResolvedRun merge(DocxRun run, {String? family}) => ResolvedRun(
    fontSizePx: run.sizeHalfPoints == null
        ? fontSizePx
        : halfPointsToPx(run.sizeHalfPoints!),
    bold: run.bold ?? bold,
    italic: run.italic ?? italic,
    underline: run.underline ?? underline,
    strike: run.strike ?? strike,
    colorHex: run.color ?? colorHex,
    fontFamily: family ?? fontFamily,
    highlight: run.highlight ?? highlight,
    shading: run.shading ?? shading,
    vertAlign: run.vertAlign ?? vertAlign,
    link: run.link ?? link,
  );
}

/// The paragraph's formatting, cascade applied.
ResolvedPara resolvePara(ParsedDocx doc, DocxBlock block) {
  final defaults = doc.docDefaults;
  final normal = doc.defaultParagraphStyle?.display ?? DocxStyleDisplay.empty;
  final style = block.styleId == null
      ? DocxStyleDisplay.empty
      : doc.styles[block.styleId]?.display ?? DocxStyleDisplay.empty;
  // The style's own values sit over the default style's, which sit over
  // docDefaults — one chain, resolved before the paragraph gets a say.
  final inherited = style.over(normal).over(_displayOf(defaults));
  final format = block.format;
  final level = _levelOf(doc, block);

  final fontFamily = resolveThemeFont(inherited.font, doc);
  final sizeHalfPoints = inherited.sizeHalfPoints ?? 22;
  final fontSizePx = halfPointsToPx(sizeHalfPoints);

  return ResolvedPara(
    align: format.align ?? inherited.align ?? DocxAlign.left,
    lineHeight: _lineHeight(
      rule: format.lineRule ?? inherited.lineRule,
      lineTwips: format.lineTwips ?? inherited.lineTwips,
      fontSizePx: fontSizePx,
      font: fontFamily,
    ),
    // Undeclared means zero (see the library note), so the ?? 0 is the answer
    // rather than a fallback.
    spaceBeforePx: twipsToPx(
      format.spaceBeforeTwips ?? inherited.spaceBeforeTwips ?? 0,
    ),
    spaceAfterPx: twipsToPx(
      format.spaceAfterTwips ?? inherited.spaceAfterTwips ?? 0,
    ),
    // Per property, never added: the paragraph wins, then its list level, then
    // its style.
    indentLeftPx: twipsToPx(
      format.indentLeftTwips ??
          level?.indentLeftTwips ??
          inherited.indentLeftTwips ??
          0,
    ),
    indentRightPx: twipsToPx(
      format.indentRightTwips ?? inherited.indentRightTwips ?? 0,
    ),
    firstLinePx: twipsToPx(
      format.indentFirstLineTwips ??
          (level?.hangingTwips == null ? null : -level!.hangingTwips!) ??
          inherited.indentFirstLineTwips ??
          0,
    ),
    base: ResolvedRun(
      fontSizePx: fontSizePx,
      bold: inherited.bold ?? false,
      italic: inherited.italic ?? false,
      underline: inherited.underline ?? false,
      strike: inherited.strike ?? false,
      colorHex: inherited.color,
      fontFamily: fontFamily,
    ),
    shadingFill: format.shadingFill,
    borders: format.borders,
  );
}

/// One run's formatting: the paragraph's baseline, then the run's character
/// style, then what the run itself says.
ResolvedRun resolveRun(ParsedDocx doc, ResolvedPara para, DocxRun run) {
  var base = para.base;
  final charStyle = run.styleId == null ? null : doc.styles[run.styleId];
  if (charStyle != null) {
    final display = charStyle.display;
    base = ResolvedRun(
      fontSizePx: display.sizeHalfPoints == null
          ? base.fontSizePx
          : halfPointsToPx(display.sizeHalfPoints!),
      bold: display.bold ?? base.bold,
      italic: display.italic ?? base.italic,
      underline: display.underline ?? base.underline,
      strike: display.strike ?? base.strike,
      colorHex: display.color ?? base.colorHex,
      fontFamily: resolveThemeFont(display.font, doc) ?? base.fontFamily,
      highlight: base.highlight,
      shading: base.shading,
      link: base.link,
    );
  }
  return base.merge(run, family: resolveThemeFont(run.font, doc));
}

DocxStyleDisplay _displayOf(DocxDocDefaults defaults) => DocxStyleDisplay(
  sizeHalfPoints: defaults.sizeHalfPoints,
  color: defaults.color,
  bold: defaults.bold,
  italic: defaults.italic,
  font: defaults.font,
  lineRule: defaults.lineRule,
  lineTwips: defaults.lineTwips,
  spaceBeforeTwips: defaults.spaceBeforeTwips,
  spaceAfterTwips: defaults.spaceAfterTwips,
);

DocxNumLevel? _levelOf(ParsedDocx doc, DocxBlock block) {
  final list = block.list;
  if (list == null) return null;
  return doc.numbering[list.numId]?[list.ilvl];
}

/// `w:spacing` turned into a multiple of the font size.
///
/// `exact` is an absolute height, so it divides by the font size to get there;
/// `atLeast` is the taller of that and the font's own line; `auto` is a multiple
/// of *single*, and single is the font's natural line height — not 1.0, which is
/// why [lineHeightFactor] exists.
double _lineHeight({
  required DocxLineRule? rule,
  required int? lineTwips,
  required double fontSizePx,
  required String? font,
}) {
  final natural = lineHeightFactor(font);
  if (lineTwips == null || lineTwips == 0) return natural;
  final asMultiple = twipsToPx(lineTwips) / fontSizePx;
  return switch (rule) {
    DocxLineRule.exact => asMultiple,
    DocxLineRule.atLeast => asMultiple > natural ? asMultiple : natural,
    // `auto`, and the same when the rule is missing: Word treats an absent
    // lineRule as a multiple.
    _ => natural * (lineTwips / 240),
  };
}

/// A font's natural single-line height, as a multiple of its size.
///
/// "Single spacing" in Word is the font's own line, and fonts disagree by up to
/// 7% — a surplus that compounds down a page until paragraphs sit visibly wrong.
/// These are genoffice's measured values (`line-metrics.ts`), which came from
/// probing the real faces rather than from a spec.
///
/// The name is used even when the face itself is missing from this computer, and
/// deliberately: a document set in Calibri should keep Calibri's line rhythm when
/// the text falls back to another sans, rather than changing spacing as well as
/// shape.
double lineHeightFactor(String? font) {
  final name = (font ?? 'Calibri').toLowerCase();
  if (name.contains('times') || name.contains('liberation serif')) return 1.15;
  if (name.contains('georgia')) return 1.1375;
  if (name.contains('cambria') || name.contains('caladea')) return 1.17;
  if (name.contains('helvetica')) return 1.0;
  if (name == 'arial' ||
      name.startsWith('arial ') ||
      name.contains('liberation sans')) {
    return 1.15;
  }
  if (name.contains('calibri') || name.contains('carlito')) return 1.22;
  if (name.contains('tahoma')) return 1.2083;
  if (name.contains('verdana')) return 1.2167;
  if (name.contains('courier')) return 1.1333;
  if (name.contains('consolas')) return 1.1667;
  if (name.contains('century') && !name.contains('gothic')) return 1.15;
  if (name.contains('book antiqua')) return 1.1;
  if (name.contains('segoe')) return 1.15;
  return 1.2;
}

/// The marker text for every block, in document order — null for anything that
/// isn't a list item.
///
/// Numbering is a *document-wide* count, not a property of a paragraph: the
/// third item of a list needs to know about the first two, and a deeper level
/// restarts every time its parent level advances. That state has to be walked
/// once over the whole body, which is why this is a list computed at load rather
/// than something a block can answer for itself.
///
/// Takes the two pieces it needs rather than a [ParsedDocx], so the parser can
/// call it *before* it has one to hand.
List<String?> listMarkers(
  List<DocxBlock> blocks,
  Map<String, Map<int, DocxNumLevel>> numbering,
) {
  final counters = <String, Map<int, int>>{};
  final markers = <String?>[];
  for (final block in blocks) {
    final list = block.list;
    if (block.kind != DocxBlockKind.listItem || list == null) {
      markers.add(null);
      continue;
    }
    final levels = numbering[list.numId];
    final level = levels?[list.ilvl];
    if (level == null) {
      markers.add('•');
      continue;
    }
    final counts = counters.putIfAbsent(list.numId, () => {});
    // A level advancing restarts everything under it — Word's rule, and what
    // makes "1.1, 1.2, 2.1" come out right instead of "1.1, 1.2, 2.3".
    counts.removeWhere((ilvl, _) => ilvl > list.ilvl);
    counts[list.ilvl] = (counts[list.ilvl] ?? level.start - 1) + 1;
    markers.add(_markerFor(level, levels!, counts, list.ilvl));
  }
  return markers;
}

/// One marker, from its level's template.
String _markerFor(
  DocxNumLevel level,
  Map<int, DocxNumLevel> levels,
  Map<int, int> counts,
  int ilvl,
) {
  if (level.numFmt == 'bullet') return _bulletGlyph(level.lvlText);
  if (level.numFmt == 'none') return '';
  var text = level.lvlText;
  // %1..%9 are the counters of levels 0..8, each formatted by *its own* level's
  // numFmt — which is how "A.1.a" works.
  for (var n = 1; n <= 9; n++) {
    final placeholder = '%$n';
    if (!text.contains(placeholder)) continue;
    final at = n - 1;
    final value = counts[at] ?? levels[at]?.start ?? 1;
    final format = at == ilvl ? level.numFmt : levels[at]?.numFmt ?? 'decimal';
    text = text.replaceAll(placeholder, formatListNumber(value, format));
  }
  return text;
}

/// Word writes bullets as private-use characters in Symbol and Wingdings, so the
/// document's own glyph is unreadable without those fonts. Map the handful Word's
/// own bullet gallery uses to characters every system has.
String _bulletGlyph(String lvlText) {
  if (lvlText.isEmpty) return '•';
  return switch (lvlText.codeUnitAt(0)) {
    0xF0B7 => '•',
    0xF0A7 => '▪',
    0xF0D8 => '➢',
    0x0076 when lvlText.length == 1 => '❖',
    0xF076 => '❖',
    0xF0FC => '✓',
    0x006F when lvlText.length == 1 => '◦',
    _ => lvlText,
  };
}

/// A counter in the format its level asked for.
String formatListNumber(int value, String numFmt) => switch (numFmt) {
  'decimalZero' => value < 10 && value >= 0 ? '0$value' : '$value',
  'lowerLetter' => _letters(value).toLowerCase(),
  'upperLetter' => _letters(value),
  'lowerRoman' => _roman(value).toLowerCase(),
  'upperRoman' => _roman(value),
  // Everything else — the CJK counting formats, enclosed digits — falls back to
  // the digits rather than to nothing, which keeps a list readable while it
  // isn't yet right.
  _ => '$value',
};

/// Word's letter sequence: 1..26 → A..Z, then 27 → AA. Repetition, not base-26 —
/// AB never appears.
String _letters(int value) {
  final n = ((value - 1) % 26) + 1;
  final repeat = (value - 1) ~/ 26 + 1;
  return String.fromCharCode(64 + n) * repeat;
}

const _romanUnits = [
  (1000, 'M'),
  (900, 'CM'),
  (500, 'D'),
  (400, 'CD'),
  (100, 'C'),
  (90, 'XC'),
  (50, 'L'),
  (40, 'XL'),
  (10, 'X'),
  (9, 'IX'),
  (5, 'V'),
  (4, 'IV'),
  (1, 'I'),
];

String _roman(int value) {
  var left = value < 1 ? 1 : value;
  final out = StringBuffer();
  for (final (size, glyph) in _romanUnits) {
    while (left >= size) {
      out.write(glyph);
      left -= size;
    }
  }
  return out.toString();
}
