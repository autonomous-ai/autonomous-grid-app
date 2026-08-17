/// Reading `word/document.xml` into blocks the renderer can draw.
///
/// One block per top-level child of `w:body`, in file order and *including* the
/// ones nothing is drawn for, so [DocxBlock.docxIndex] stays the index a save
/// patches by. Paragraphs inside table cells are parsed by the same code with no
/// index — a cell is a small document, and rendering it any other way is how a
/// bulleted list in a cell stops looking like one.
///
/// Pure apart from the zip it is handed: bytes in, model out, no filesystem.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'docx_model.dart';
import 'docx_parts.dart';
import 'docx_resolve.dart';
import 'docx_xml.dart';

/// Reads [bytes] for display — or null when there is no readable document in it.
///
/// Deliberately separate from `DocxFile.open`, which reads the same file for
/// *editing*: that one needs the paragraphs as flat lines and the zip kept for a
/// byte-preserving save, this one needs the formatting and none of that. Two
/// readers over one file is the honest shape while the editor is text-only —
/// they meet again when editing becomes block-level.
ParsedDocx? parseDocxLayout(Uint8List bytes) {
  final zip = _unzip(bytes);
  if (zip == null) return null;
  final body = _bodyOf(zip);
  if (body == null) return null;

  final theme = parseThemeFonts(zip);
  final relationships = parseRelationships(zip);
  final styles = parseStyles(zip);
  final blocks = <DocxBlock>[];
  var index = 0;
  for (final element in body.childElements) {
    blocks.add(switch (element.name.local) {
      'p' => _parseParagraph(element, zip, relationships, styles, index),
      'tbl' => DocxBlock(
        kind: DocxBlockKind.table,
        docxIndex: index,
        table: _parseTable(element, zip, relationships, styles),
      ),
      // sectPr and the loose range markers Word leaves at body level: they
      // occupy an index, so they get a block, and they draw nothing.
      'sectPr' => DocxBlock(
        kind: DocxBlockKind.passthrough,
        docxIndex: index,
        hidden: true,
      ),
      // A content control or a tracked block wrapper: its paragraphs are in
      // there, so show them rather than dropping the content.
      _ => _parseWrapper(element, zip, relationships, styles, index),
    });
    index++;
  }

  final numbering = parseNumbering(zip);
  return ParsedDocx(
    blocks: blocks,
    styles: styles,
    numbering: numbering,
    // Walked here, once, because it is the one thing about a block that depends
    // on every block before it.
    markers: listMarkers(blocks, numbering),
    docDefaults: parseDocDefaults(zip),
    section: _parseSection(body),
    themeMinorFont: theme.minor,
    themeMajorFont: theme.major,
  );
}

/// One `w:p`.
///
/// What it *is* — paragraph, heading, list item or a picture on its own line —
/// falls out of what it carries, in that order of precedence: a picture with no
/// text is a picture, a `w:numPr` (its own or its style's) makes a list item, a
/// heading style makes a heading.
DocxBlock _parseParagraph(
  XmlElement p,
  Archive zip,
  Map<String, String> relationships,
  Map<String, DocxStyle> styles,
  int? index,
) {
  final pPr = childNamed(p, 'pPr');
  final styleId = valOf(pPr, 'pStyle');
  final runs = _parseRuns(p, relationships);
  final image = _parseImage(p, zip, relationships);
  final hasText = runs.any((r) => r.text.trim().isNotEmpty);
  final format = _parseParaFormat(pPr);

  if (image != null && !hasText) {
    return DocxBlock(
      kind: DocxBlockKind.image,
      docxIndex: index,
      styleId: styleId,
      format: format,
      image: image,
    );
  }

  final numPr = childNamed(pPr, 'numPr');
  final ownNumId = valOf(numPr, 'numId');
  final styleList = styleId == null ? null : styles[styleId]?.list;
  // "numId 0" is Word's way of saying *not* a list — a paragraph turning its
  // style's numbering off. Read as a list, it draws a marker nobody asked for.
  final list = ownNumId != null && ownNumId != '0'
      ? (numId: ownNumId, ilvl: intVal(numPr, 'ilvl') ?? 0)
      : (ownNumId == '0' ? null : styleList);
  final level = styleId == null ? null : styles[styleId]?.headingLevel;

  return DocxBlock(
    kind: list != null
        ? DocxBlockKind.listItem
        : (level != null ? DocxBlockKind.heading : DocxBlockKind.paragraph),
    docxIndex: index,
    level: level,
    styleId: styleId,
    list: list,
    format: format,
    runs: runs,
  );
}

/// A body-level element that isn't a paragraph or a table: read the paragraphs
/// out of it and show the first, so a content control's text isn't a blank gap.
DocxBlock _parseWrapper(
  XmlElement element,
  Archive zip,
  Map<String, String> relationships,
  Map<String, DocxStyle> styles,
  int index,
) {
  final paragraph = descendantNamed(element, 'p');
  if (paragraph == null) {
    return DocxBlock(
      kind: DocxBlockKind.passthrough,
      docxIndex: index,
      hidden: true,
    );
  }
  final parsed = _parseParagraph(paragraph, zip, relationships, styles, index);
  return DocxBlock(
    kind: DocxBlockKind.passthrough,
    docxIndex: index,
    styleId: parsed.styleId,
    format: parsed.format,
    runs: parsed.runs,
    image: parsed.image,
  );
}

DocxParaFormat _parseParaFormat(XmlElement? pPr) {
  if (pPr == null) return DocxParaFormat.empty;
  final spacing = childNamed(pPr, 'spacing');
  final indent = childNamed(pPr, 'ind');
  final hanging = intAttr(indent, 'hanging');
  final firstLine = intAttr(indent, 'firstLine');
  final borders = childNamed(pPr, 'pBdr');
  return DocxParaFormat(
    align: alignOf(valOf(pPr, 'jc')),
    lineRule: lineRuleOf(attr(spacing, 'lineRule')),
    lineTwips: intAttr(spacing, 'line'),
    indentLeftTwips: intAttr(indent, 'left') ?? intAttr(indent, 'start'),
    indentRightTwips: intAttr(indent, 'right') ?? intAttr(indent, 'end'),
    indentFirstLineTwips: hanging != null ? -hanging : firstLine,
    spaceBeforeTwips: intAttr(spacing, 'before'),
    spaceAfterTwips: intAttr(spacing, 'after'),
    contextualSpacing: onOff(pPr, 'contextualSpacing'),
    shadingFill: colorVal(attr(childNamed(pPr, 'shd'), 'fill')),
    borders: borders == null ? null : _borderSides(borders),
    pageBreakBefore: onOff(pPr, 'pageBreakBefore'),
  );
}

/// Which sides a `w:pBdr` actually draws, as a subset of `tblr`.
String? _borderSides(XmlElement pBdr) {
  const sides = {'top': 't', 'bottom': 'b', 'left': 'l', 'right': 'r'};
  final out = StringBuffer();
  for (final entry in sides.entries) {
    final side = childNamed(pBdr, entry.key);
    if (side == null) continue;
    final kind = attr(side, 'val');
    if (kind == null || kind == 'none' || kind == 'nil') continue;
    out.write(entry.value);
  }
  return out.isEmpty ? null : out.toString();
}

/// The paragraph's runs, in document order, following everything that can hold
/// one.
///
/// `w:ins` is walked into (a tracked insertion is text that is *there*), `w:del`
/// is skipped (a tracked deletion is text that is not), and hyperlinks pass their
/// target down to the runs inside them.
List<DocxRun> _parseRuns(
  XmlElement container,
  Map<String, String> relationships, {
  String? link,
}) {
  final runs = <DocxRun>[];
  for (final child in container.childElements) {
    switch (child.name.local) {
      case 'r':
        final run = _parseRun(child, link);
        if (run != null) runs.add(run);
      case 'hyperlink':
        final target = attr(child, 'id');
        runs.addAll(
          _parseRuns(
            child,
            relationships,
            link: target == null ? link : relationships[target] ?? link,
          ),
        );
      case 'ins' || 'smartTag' || 'sdt' || 'sdtContent' || 'fldSimple':
        runs.addAll(_parseRuns(child, relationships, link: link));
      case 'del':
        continue;
      // A formula: its text is in m:t runs, which the generic walk reaches, so
      // the reader shows the characters rather than an empty line.
      case 'oMath' || 'oMathPara':
        runs.addAll(_mathRuns(child));
    }
  }
  return runs;
}

DocxRun? _parseRun(XmlElement r, String? link) {
  final text = _runText(r);
  if (text.isEmpty) return null;
  final rPr = childNamed(r, 'rPr');
  final shading = childNamed(rPr, 'shd');
  return DocxRun(
    text: text,
    bold: onOff(rPr, 'b'),
    italic: onOff(rPr, 'i'),
    underline: _underline(rPr),
    strike: onOff(rPr, 'strike'),
    color: colorVal(valOf(rPr, 'color')),
    sizeHalfPoints: intVal(rPr, 'sz'),
    font: fontOf(childNamed(rPr, 'rFonts')),
    highlight: valOf(rPr, 'highlight'),
    shading: colorVal(attr(shading, 'fill')),
    vertAlign: valOf(rPr, 'vertAlign'),
    styleId: valOf(rPr, 'rStyle'),
    link: link,
  );
}

bool? _underline(XmlElement? rPr) {
  final value = valOf(rPr, 'u');
  if (value == null) return null;
  return value.trim().toLowerCase() != 'none';
}

/// A run's characters, with the elements that *are* characters turned into them.
String _runText(XmlElement r) {
  final out = StringBuffer();
  for (final node in r.descendantElements) {
    switch (node.name.local) {
      case 't':
        out.write(node.innerText);
      case 'tab':
        out.write('\t');
      case 'br' || 'cr':
        out.write('\n');
      case 'noBreakHyphen':
        out.write('-');
      case 'softHyphen':
        break;
      case 'sym':
        // A symbol-font glyph, written as a code point in a private-use range.
        final code = int.tryParse(attr(node, 'char') ?? '', radix: 16);
        if (code != null) out.write(String.fromCharCode(code));
    }
  }
  return out.toString();
}

/// A formula's characters, in order — no layout, which is honest: this build
/// shows the symbols an equation is made of, not the equation.
List<DocxRun> _mathRuns(XmlElement math) {
  final text = StringBuffer();
  for (final node in math.descendantElements) {
    if (node.name.local == 't') text.write(node.innerText);
  }
  return text.isEmpty ? const [] : [DocxRun(text: text.toString())];
}

/// The first picture in the paragraph, with its bytes.
///
/// Null when there is no drawing, or when there is one whose media part is
/// missing from the zip — a broken relationship, which happens in files that
/// have been through a converter.
DocxImage? _parseImage(
  XmlElement p,
  Archive zip,
  Map<String, String> relationships,
) {
  final drawing = descendantNamed(p, 'drawing');
  if (drawing == null) return null;
  final embed = attr(descendantNamed(drawing, 'blip'), 'embed');
  final path = embed == null ? null : relationships[embed];
  final bytes = path == null ? null : zip.findFile(path)?.readBytes();
  if (bytes == null) return null;
  final extent = descendantNamed(drawing, 'extent');
  return DocxImage(
    bytes: bytes,
    widthPx: intAttr(extent, 'cx') == null
        ? null
        : emuToPx(intAttr(extent, 'cx')!),
    heightPx: intAttr(extent, 'cy') == null
        ? null
        : emuToPx(intAttr(extent, 'cy')!),
    align: alignOf(valOf(childNamed(p, 'pPr'), 'jc')),
  );
}

/// One `w:tbl`.
DocxTable _parseTable(
  XmlElement tbl,
  Archive zip,
  Map<String, String> relationships,
  Map<String, DocxStyle> styles,
) {
  final tblPr = childNamed(tbl, 'tblPr');
  final borders = childNamed(tblPr, 'tblBorders');
  final margins = childNamed(tblPr, 'tblCellMar');
  return DocxTable(
    rows: [
      for (final tr in childrenNamed(tbl, 'tr'))
        _parseRow(tr, zip, relationships, styles),
    ],
    gridTwips: [
      for (final col in childrenNamed(childNamed(tbl, 'tblGrid'), 'gridCol'))
        intAttr(col, 'w') ?? 0,
    ],
    styleId: valOf(tblPr, 'tblStyle'),
    borders: borders == null ? null : _borders(borders),
    cellMarginsTwips: margins == null
        ? null
        : [
            _marginTwips(margins, 'top'),
            _marginTwips(margins, 'left') ?? _marginTwips(margins, 'start'),
            _marginTwips(margins, 'bottom'),
            _marginTwips(margins, 'right') ?? _marginTwips(margins, 'end'),
          ].map((v) => v ?? 0).toList(),
    indentTwips: intAttr(childNamed(tblPr, 'tblInd'), 'w'),
  );
}

int? _marginTwips(XmlElement margins, String side) =>
    intAttr(childNamed(margins, side), 'w');

DocxTableRow _parseRow(
  XmlElement tr,
  Archive zip,
  Map<String, String> relationships,
  Map<String, DocxStyle> styles,
) {
  final trPr = childNamed(tr, 'trPr');
  return DocxTableRow(
    isHeader: onOff(trPr, 'tblHeader') ?? false,
    cells: [
      for (final tc in childrenNamed(tr, 'tc'))
        _parseCell(tc, zip, relationships, styles),
    ],
  );
}

DocxTableCell _parseCell(
  XmlElement tc,
  Archive zip,
  Map<String, String> relationships,
  Map<String, DocxStyle> styles,
) {
  final tcPr = childNamed(tc, 'tcPr');
  final vMerge = childNamed(tcPr, 'vMerge');
  final borders = childNamed(tcPr, 'tcBorders');
  return DocxTableCell(
    blocks: [
      for (final child in tc.childElements)
        if (child.name.local == 'p')
          _parseParagraph(child, zip, relationships, styles, null)
        // A nested table draws as its own block, which the renderer already
        // knows how to do.
        else if (child.name.local == 'tbl')
          DocxBlock(
            kind: DocxBlockKind.table,
            docxIndex: null,
            table: _parseTable(child, zip, relationships, styles),
          ),
    ],
    widthTwips: intAttr(childNamed(tcPr, 'tcW'), 'w'),
    gridSpan: intVal(tcPr, 'gridSpan') ?? 1,
    // `w:vMerge` with no val — or val="continue" — is a cell that hides under
    // the one above. Only `restart` begins a merged run.
    vMergeContinue: vMerge != null && attr(vMerge, 'val') != 'restart',
    shadingFill: colorVal(attr(childNamed(tcPr, 'shd'), 'fill')),
    borders: borders == null ? null : _borders(borders),
  );
}

DocxBorders _borders(XmlElement element) => DocxBorders(
  top: _side(childNamed(element, 'top')),
  left: _side(childNamed(element, 'left') ?? childNamed(element, 'start')),
  bottom: _side(childNamed(element, 'bottom')),
  right: _side(childNamed(element, 'right') ?? childNamed(element, 'end')),
);

/// One border line — null when the element says there is none, so an explicit
/// `w:val="none"` can override an inherited frame.
DocxBorderSide? _side(XmlElement? element) {
  if (element == null) return null;
  final kind = attr(element, 'val');
  if (kind == 'none' || kind == 'nil') {
    return const DocxBorderSide(widthPx: 0, color: '000000');
  }
  return DocxBorderSide(
    // Word writes no w:sz for a default single line; that line is 0.5pt.
    widthPx: borderWidthPx(intAttr(element, 'sz') ?? 4),
    color: colorVal(attr(element, 'color')) ?? '000000',
  );
}

/// The page setup, from the body's trailing `w:sectPr`.
///
/// The last one in the body governs the document's last section, which for a
/// single-section file — nearly all of them — is the whole thing. Multi-section
/// documents keep a `w:sectPr` inside a paragraph's `pPr` per section; this build
/// draws one page size, so it takes the final word.
DocxSection _parseSection(XmlElement body) {
  final sectPr = childrenNamed(body, 'sectPr').isEmpty
      ? descendantNamed(body, 'sectPr')
      : childrenNamed(body, 'sectPr').last;
  if (sectPr == null) return const DocxSection();
  final size = childNamed(sectPr, 'pgSz');
  final margin = childNamed(sectPr, 'pgMar');
  const fallback = DocxSection();
  return DocxSection(
    pageWidthTwips: intAttr(size, 'w') ?? fallback.pageWidthTwips,
    pageHeightTwips: intAttr(size, 'h') ?? fallback.pageHeightTwips,
    marginTopTwips: intAttr(margin, 'top') ?? fallback.marginTopTwips,
    marginRightTwips: intAttr(margin, 'right') ?? fallback.marginRightTwips,
    marginBottomTwips: intAttr(margin, 'bottom') ?? fallback.marginBottomTwips,
    marginLeftTwips: intAttr(margin, 'left') ?? fallback.marginLeftTwips,
  );
}

XmlElement? _bodyOf(Archive zip) {
  final bytes = zip.findFile('word/document.xml')?.readBytes();
  if (bytes == null) return null;
  try {
    final document = XmlDocument.parse(
      utf8.decode(bytes, allowMalformed: true),
    );
    return childNamed(document.rootElement, 'body');
  } on XmlException {
    return null;
  }
}

Archive? _unzip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object {
    return null;
  }
}
