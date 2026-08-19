/// Writing a paragraph's formatting back into `word/document.xml`.
///
/// The other half of `docx_format.dart`, which reads the same properties, and
/// the surgical counterpart to `docx_edit.dart`'s text patch: this **never
/// rebuilds a paragraph**. It reaches into the `w:pPr` the paragraph already has
/// (making one only when there is none), sets the one attribute the user
/// pressed, and leaves every run, every field code and every picture where it
/// was. So a bold word in the middle of a sentence survives its paragraph being
/// centred — which retyping that paragraph would have flattened.
///
/// Pure: an element in, the same element mutated, no filesystem and no zip.
///
/// **Order is not decoration.** `w:pPr` and `w:rPr` are XSD *sequences*, so Word
/// rejects a document whose `w:jc` sits before its `w:spacing`. Anything new
/// goes in at the position [_pPrOrder] / [_rPrOrder] gives it, among whatever
/// the file already had.
library;

import 'package:xml/xml.dart';

import 'docx_format.dart';
import 'docx_paragraph_style.dart';

/// `CT_PPr`'s sequence, in the schema's order. Only the elements this writer
/// places need to be here, plus the ones it has to sort itself against.
const _pPrOrder = [
  'pStyle',
  'keepNext',
  'keepLines',
  'pageBreakBefore',
  'framePr',
  'widowControl',
  'numPr',
  'suppressLineNumbers',
  'pBdr',
  'shd',
  'tabs',
  'suppressAutoHyphens',
  'kinsoku',
  'wordWrap',
  'overflowPunct',
  'topLinePunct',
  'autoSpaceDE',
  'autoSpaceDN',
  'bidi',
  'adjustRightInd',
  'snapToGrid',
  'spacing',
  'ind',
  'contextualSpacing',
  'mirrorIndents',
  'suppressOverlap',
  'jc',
  'textDirection',
  'textAlignment',
  'textboxTightWrap',
  'outlineLvl',
  'divId',
  'cnfStyle',
  'rPr',
  'sectPr',
];

/// `CT_RPr`'s sequence, same rule.
const _rPrOrder = [
  'rStyle',
  'rFonts',
  'b',
  'bCs',
  'i',
  'iCs',
  'caps',
  'smallCaps',
  'strike',
  'dstrike',
  'outline',
  'shadow',
  'emboss',
  'imprint',
  'noProof',
  'snapToGrid',
  'vanish',
  'webHidden',
  'color',
  'spacing',
  'w',
  'kern',
  'position',
  'sz',
  'szCs',
  'highlight',
  'u',
  'effect',
  'bdr',
  'shd',
  'fitText',
  'vertAlign',
  'rtl',
  'cs',
  'em',
  'lang',
];

/// Word's name for each alignment.
const _alignNames = {
  DocxTextAlign.left: 'left',
  DocxTextAlign.center: 'center',
  DocxTextAlign.right: 'right',
  // Not "justify": `w:jc` calls both edges "both", and a value Word doesn't
  // know is a value it ignores.
  DocxTextAlign.justify: 'both',
};

/// Apply [style] to [paragraph], in place.
///
/// Paragraph properties land on the paragraph; character properties land on
/// **every run in it**, and on the paragraph mark's own `w:rPr` so an empty
/// paragraph keeps the choice for the first thing typed into it. That is what
/// makes this a per-paragraph toolbar rather than a per-run one — see the note
/// in `office_toolbar.dart` on what that costs.
void applyParagraphStyle(XmlElement paragraph, DocxParagraphStyle style) {
  if (style.isEmpty) return;
  final prefix = paragraph.name.prefix;
  if (style.align != null ||
      style.lineSpacing != null ||
      style.indentLeftTwips != null ||
      style.indentRightTwips != null ||
      style.firstLineTwips != null) {
    _writeParagraphProps(_ensurePPr(paragraph, prefix), style, prefix);
  }
  if (style.bold == null &&
      style.italic == null &&
      style.underline == null &&
      style.fontFamily == null &&
      style.fontHalfPoints == null) {
    return;
  }
  for (final run in _runsOf(paragraph)) {
    _writeRunProps(_ensureRunProps(run, prefix), style, prefix);
  }
  // The paragraph mark carries its own run properties, and they are what the
  // next character typed into an empty paragraph inherits. Skipping it is why a
  // blank line "wouldn't take" a font in the first draft of this.
  //
  // Placed by [_pPrOrder], because here `rPr` is a child of `w:pPr` and takes
  // its slot among that sequence — not by [_rPrOrder], which describes what
  // goes *inside* an `rPr`.
  _writeRunProps(
    _ensureChild(_ensurePPr(paragraph, prefix), 'rPr', prefix, _pPrOrder),
    style,
    prefix,
  );
}

void _writeParagraphProps(
  XmlElement pPr,
  DocxParagraphStyle style,
  String? prefix,
) {
  if (style.align case final align?) {
    _setVal(_ensureChild(pPr, 'jc', prefix, _pPrOrder), _alignNames[align]!);
  }
  if (style.lineSpacing case final spacing?) {
    final element = _ensureChild(pPr, 'spacing', prefix, _pPrOrder);
    // 240ths of a line, and `auto` so the value is read as a multiple rather
    // than as an exact height — `exact` would clip a paragraph whose font is
    // bigger than the line it was given.
    _setAttr(element, 'line', '${(spacing * 240).round()}');
    _setAttr(element, 'lineRule', 'auto');
  }
  if (style.indentLeftTwips == null &&
      style.indentRightTwips == null &&
      style.firstLineTwips == null) {
    return;
  }
  final indent = _ensureChild(pPr, 'ind', prefix, _pPrOrder);
  if (style.indentLeftTwips case final left?) {
    _setAttr(indent, 'left', '$left');
    // `w:start` is the same measurement under OOXML's later name, and a file
    // carrying both would be read by whichever one Word looked at first.
    _removeAttr(indent, 'start');
  }
  if (style.indentRightTwips case final right?) {
    _setAttr(indent, 'right', '$right');
    _removeAttr(indent, 'end');
  }
  if (style.firstLineTwips case final first?) {
    // One attribute or the other, never both: Word treats a paragraph carrying
    // `w:firstLine` and `w:hanging` together as hanging, so leaving the old one
    // behind is how a first-line indent silently becomes a hang.
    _removeAttr(indent, first < 0 ? 'firstLine' : 'hanging');
    _setAttr(indent, first < 0 ? 'hanging' : 'firstLine', '${first.abs()}');
  }
}

void _writeRunProps(XmlElement rPr, DocxParagraphStyle style, String? prefix) {
  // "1"/"0" rather than the element's presence alone: a bare `<w:b/>` can only
  // say bold *on*, so turning bold off in a paragraph whose style is bold needs
  // the explicit off — deleting the element would hand it back to the style.
  if (style.bold case final bold?) {
    _setVal(_ensureChild(rPr, 'b', prefix, _rPrOrder), bold ? '1' : '0');
  }
  if (style.italic case final italic?) {
    _setVal(_ensureChild(rPr, 'i', prefix, _rPrOrder), italic ? '1' : '0');
  }
  if (style.underline case final underline?) {
    _setVal(
      _ensureChild(rPr, 'u', prefix, _rPrOrder),
      underline ? 'single' : 'none',
    );
  }
  if (style.fontFamily case final font?) {
    final fonts = _ensureChild(rPr, 'rFonts', prefix, _rPrOrder);
    // All four scripts, because a document that names only `w:ascii` renders in
    // the old face the moment a line has a Vietnamese diacritic or a quotation
    // mark in it — `w:hAnsi` is what carries those.
    for (final script in ['ascii', 'hAnsi', 'cs', 'eastAsia']) {
      _setAttr(fonts, script, font);
    }
    // A theme font wins over a named one, so it has to go or the choice does
    // nothing at all.
    for (final script in [
      'asciiTheme',
      'hAnsiTheme',
      'cstheme',
      'eastAsiaTheme',
    ]) {
      _removeAttr(fonts, script);
    }
  }
  if (style.fontHalfPoints case final size?) {
    _setVal(_ensureChild(rPr, 'sz', prefix, _rPrOrder), '$size');
    // The complex-script size beside it, or the same text sets at two sizes
    // depending on which script Word decides a character belongs to.
    _setVal(_ensureChild(rPr, 'szCs', prefix, _rPrOrder), '$size');
  }
}

/// Every run in the paragraph, including those inside a hyperlink or a tracked
/// insertion — a link is still words on the page, and it takes the font too.
List<XmlElement> _runsOf(XmlElement paragraph) => [
  for (final node in paragraph.descendants.whereType<XmlElement>())
    if (node.name.local == 'r') node,
];

/// The run's `w:rPr`, which by the schema is its **first** child.
///
/// Its own function rather than [_ensureChild] with a sequence, because a run's
/// children are not a sequence this file describes: `w:t`, `w:tab`, `w:br` and
/// the rest come in any order after the properties. Asking [_ensureChild] to
/// place it against [_rPrOrder] — the list of what goes *inside* an rPr — ranked
/// both the rPr and the `w:t` as unknown and dropped the new rPr **after the
/// text**, where Word ignores it. That is exactly the everyday case: pressing
/// Bold on a paragraph whose run has no formatting yet, which is every run in a
/// document Grid itself created.
XmlElement _ensureRunProps(XmlElement run, String? prefix) {
  for (final child in run.childElements) {
    if (child.name.local == 'rPr') return child;
  }
  final made = XmlElement(XmlName.parts('rPr', prefix: prefix));
  run.children.insert(0, made);
  return made;
}

/// The paragraph's `w:pPr`, which by the schema is its **first** child.
XmlElement _ensurePPr(XmlElement paragraph, String? prefix) {
  for (final child in paragraph.childElements) {
    if (child.name.local == 'pPr') return child;
  }
  final made = XmlElement(XmlName.parts('pPr', prefix: prefix));
  paragraph.children.insert(0, made);
  return made;
}

/// [parent]'s child named [local], made and placed in schema order when there
/// is none.
XmlElement _ensureChild(
  XmlElement parent,
  String local,
  String? prefix,
  List<String> order,
) {
  for (final child in parent.childElements) {
    if (child.name.local == local) return child;
  }
  final made = XmlElement(XmlName.parts(local, prefix: prefix));
  parent.children.insert(_slotFor(parent, local, order), made);
  return made;
}

/// Where a new [local] belongs among [parent]'s children.
///
/// Just past the last child the schema puts *before* it. An element the order
/// doesn't name is treated as belonging before everything — it is something
/// this writer doesn't place, and the safe assumption is that the file already
/// had it in the right spot.
int _slotFor(XmlElement parent, String local, List<String> order) {
  final rank = order.indexOf(local);
  var slot = 0;
  for (var i = 0; i < parent.children.length; i++) {
    final child = parent.children[i];
    if (child is! XmlElement) continue;
    final at = order.indexOf(child.name.local);
    if (at >= 0 && at > rank) return slot;
    slot = i + 1;
  }
  return slot;
}

void _setVal(XmlElement element, String value) =>
    _setAttr(element, 'val', value);

void _setAttr(XmlElement element, String local, String value) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == local) {
      attribute.value = value;
      return;
    }
  }
  element.attributes.add(
    XmlAttribute(XmlName.parts(local, prefix: element.name.prefix), value),
  );
}

void _removeAttr(XmlElement element, String local) =>
    element.attributes.removeWhere((a) => a.name.local == local);
