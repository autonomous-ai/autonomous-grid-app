/// The parts of a `.docx` that are *about* the document rather than in it:
/// `styles.xml`, `numbering.xml`, the theme's fonts, and the relationship table
/// that turns an `r:id` into a file in the zip.
///
/// They are read before the body, because the body is unreadable without them: a
/// paragraph that says only `w:pStyle w:val="Heading1"` has its size, its font
/// and its spacing over here, and a run that says `w:asciiTheme="minorHAnsi"`
/// names a font that only the theme knows.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'docx_model.dart';
import 'docx_xml.dart';

/// `styles.xml` read into styleId → style, with every `w:basedOn` chain already
/// collapsed.
///
/// Collapsed here rather than at render time for the reason genoffice gives: the
/// chain is walked once per document instead of once per paragraph, and the
/// renderer can't get the order wrong because it never sees the chain.
Map<String, DocxStyle> parseStyles(Archive zip) {
  final root = _rootOf(zip, 'word/styles.xml');
  if (root == null) return const {};
  final raw = <String, DocxStyle>{};
  for (final element in childrenNamed(root, 'style')) {
    final id = attr(element, 'styleId');
    if (id == null) continue;
    raw[id] = _parseStyle(id, element);
  }
  return {
    for (final entry in raw.entries)
      entry.key: _withInheritedDisplay(entry.value, raw),
  };
}

DocxStyle _parseStyle(String id, XmlElement element) {
  final pPr = childNamed(element, 'pPr');
  final numPr = childNamed(pPr, 'numPr');
  final numId = valOf(numPr, 'numId');
  final name = valOf(element, 'name');
  return DocxStyle(
    styleId: id,
    type: attr(element, 'type') ?? 'paragraph',
    name: name,
    basedOn: valOf(element, 'basedOn'),
    headingLevel: _headingLevel(id, name, pPr),
    display: styleDisplayOf(pPr, childNamed(element, 'rPr')),
    list: numId == null
        ? null
        : (numId: numId, ilvl: intVal(numPr, 'ilvl') ?? 0),
    isDefault: attr(element, 'default') == '1',
  );
}

/// Which heading a style is, if it is one.
///
/// Three ways to tell, because documents use all three: the style's display name
/// ("heading 1" — Word's own naming), its id (`Heading1`), and `w:outlineLvl`,
/// which is what a document with renamed styles has left.
int? _headingLevel(String id, String? name, XmlElement? pPr) {
  final outline = intVal(pPr, 'outlineLvl');
  if (outline != null && outline >= 0 && outline <= 8) return outline + 1;
  for (final candidate in [name, id]) {
    final match = RegExp(
      r'^heading\s*([1-9])$',
      caseSensitive: false,
    ).firstMatch(candidate?.trim().replaceAll(' ', '') ?? '');
    if (match != null) return int.parse(match.group(1)!);
  }
  return null;
}

/// [style] with its ancestors showing through — its own values win at every
/// field, which is what `w:basedOn` means.
///
/// The visited set is not defensive tidiness: a `basedOn` cycle is a real thing
/// to find in the wild (a style based on itself, or two based on each other),
/// and without the guard it is an infinite loop at file-open time.
DocxStyle _withInheritedDisplay(DocxStyle style, Map<String, DocxStyle> all) {
  var display = style.display;
  var headingLevel = style.headingLevel;
  var list = style.list;
  final visited = <String>{style.styleId};
  var parent = style.basedOn;
  while (parent != null && visited.add(parent)) {
    final ancestor = all[parent];
    if (ancestor == null) break;
    display = display.over(ancestor.display);
    headingLevel ??= ancestor.headingLevel;
    list ??= ancestor.list;
    parent = ancestor.basedOn;
  }
  return DocxStyle(
    styleId: style.styleId,
    type: style.type,
    name: style.name,
    basedOn: style.basedOn,
    headingLevel: headingLevel,
    display: display,
    list: list,
    isDefault: style.isDefault,
  );
}

/// The formatting a `w:pPr` + `w:rPr` pair states, as a style contribution.
///
/// Shared by `styles.xml` and `w:docDefaults`, which carry the same two elements
/// and would otherwise be read by two copies of this.
DocxStyleDisplay styleDisplayOf(XmlElement? pPr, XmlElement? rPr) {
  final spacing = childNamed(pPr, 'spacing');
  final indent = childNamed(pPr, 'ind');
  final hanging = intAttr(indent, 'hanging');
  final firstLine = intAttr(indent, 'firstLine');
  return DocxStyleDisplay(
    sizeHalfPoints: intVal(rPr, 'sz'),
    color: colorVal(valOf(rPr, 'color')),
    bold: onOff(rPr, 'b'),
    italic: onOff(rPr, 'i'),
    underline: _underlineOf(rPr),
    strike: onOff(rPr, 'strike'),
    font: fontOf(childNamed(rPr, 'rFonts')),
    align: alignOf(valOf(pPr, 'jc')),
    lineRule: lineRuleOf(attr(spacing, 'lineRule')),
    lineTwips: intAttr(spacing, 'line'),
    spaceBeforeTwips: intAttr(spacing, 'before'),
    spaceAfterTwips: intAttr(spacing, 'after'),
    indentLeftTwips: intAttr(indent, 'left') ?? intAttr(indent, 'start'),
    indentRightTwips: intAttr(indent, 'right') ?? intAttr(indent, 'end'),
    // One axis for two attributes that are each other's opposite — and hanging
    // wins, because a document that sets both means the hang (Word writes the
    // pair when a list level is edited).
    indentFirstLineTwips: hanging != null ? -hanging : firstLine,
    contextualSpacing: onOff(pPr, 'contextualSpacing'),
  );
}

/// `w:u` is an enumeration, not a switch: `none` is off, anything else — single,
/// double, wavy, dotted — is a line this renderer draws the one way it can.
bool? _underlineOf(XmlElement? rPr) {
  final value = valOf(rPr, 'u');
  if (value == null) return null;
  return value.trim().toLowerCase() != 'none';
}

/// The face a `w:rFonts` names, preferring the East Asian slot.
///
/// East Asian first because that is the slot that carries the face for CJK text,
/// and a document that names both usually means the Latin one only for its
/// digits. Theme references (`w:asciiTheme="minorHAnsi"`) are left to
/// [resolveThemeFont] — they are not font names.
String? fontOf(XmlElement? rFonts) {
  if (rFonts == null) return null;
  for (final slot in ['eastAsia', 'ascii', 'hAnsi', 'cs']) {
    final name = attr(rFonts, slot);
    if (name != null && name.trim().isNotEmpty) return name.trim();
  }
  for (final slot in ['asciiTheme', 'hAnsiTheme', 'eastAsiaTheme']) {
    final theme = attr(rFonts, slot);
    if (theme != null && theme.trim().isNotEmpty) return '+${theme.trim()}';
  }
  return null;
}

/// A font name that came from a theme reference (`+minorHAnsi`), resolved to the
/// face the theme actually names. Anything else passes through.
String? resolveThemeFont(String? font, ParsedDocx doc) {
  if (font == null || !font.startsWith('+')) return font;
  final reference = font.substring(1).toLowerCase();
  if (reference.startsWith('major')) return doc.themeMajorFont;
  if (reference.startsWith('minor')) return doc.themeMinorFont;
  return null;
}

DocxAlign? alignOf(String? raw) => switch (raw?.trim()) {
  'center' => DocxAlign.center,
  'right' || 'end' => DocxAlign.right,
  'both' || 'justify' || 'distribute' => DocxAlign.justify,
  'left' || 'start' => DocxAlign.left,
  _ => null,
};

DocxLineRule? lineRuleOf(String? raw) => switch (raw?.trim()) {
  'auto' => DocxLineRule.auto,
  'atLeast' => DocxLineRule.atLeast,
  'exact' || 'exactly' => DocxLineRule.exact,
  _ => null,
};

/// `w:docDefaults` — what every paragraph and run in the document starts from.
DocxDocDefaults parseDocDefaults(Archive zip) {
  final root = _rootOf(zip, 'word/styles.xml');
  final defaults = childNamed(root, 'docDefaults');
  if (defaults == null) return DocxDocDefaults.empty;
  final display = styleDisplayOf(
    childNamed(childNamed(defaults, 'pPrDefault'), 'pPr'),
    childNamed(childNamed(defaults, 'rPrDefault'), 'rPr'),
  );
  return DocxDocDefaults(
    sizeHalfPoints: display.sizeHalfPoints,
    font: display.font,
    color: display.color,
    bold: display.bold,
    italic: display.italic,
    lineRule: display.lineRule,
    lineTwips: display.lineTwips,
    spaceBeforeTwips: display.spaceBeforeTwips,
    spaceAfterTwips: display.spaceAfterTwips,
  );
}

/// `numbering.xml` read into numId → (level → definition).
///
/// Two indirections, both of which matter: a `w:num` points at a `w:abstractNum`
/// (several lists can share one definition), and a `w:lvlOverride` on the `w:num`
/// can replace a level or restart its counter. A reader that only followed the
/// first indirection numbers a document's second list starting from the first
/// one's count.
Map<String, Map<int, DocxNumLevel>> parseNumbering(Archive zip) {
  final root = _rootOf(zip, 'word/numbering.xml');
  if (root == null) return const {};
  final abstracts = <String, Map<int, DocxNumLevel>>{};
  for (final element in childrenNamed(root, 'abstractNum')) {
    final id = attr(element, 'abstractNumId');
    if (id == null) continue;
    abstracts[id] = _levelsOf(element);
  }
  final numbering = <String, Map<int, DocxNumLevel>>{};
  for (final element in childrenNamed(root, 'num')) {
    final id = attr(element, 'numId');
    if (id == null) continue;
    final abstractId = valOf(element, 'abstractNumId');
    final levels = {...?abstracts[abstractId]};
    for (final override in childrenNamed(element, 'lvlOverride')) {
      final ilvl = intAttr(override, 'ilvl');
      if (ilvl == null) continue;
      final replacement = _levelOf(childNamed(override, 'lvl'));
      if (replacement != null) {
        levels[ilvl] = replacement;
        continue;
      }
      final start = intVal(override, 'startOverride');
      final current = levels[ilvl];
      if (start != null && current != null) {
        levels[ilvl] = DocxNumLevel(
          numFmt: current.numFmt,
          lvlText: current.lvlText,
          start: start,
          indentLeftTwips: current.indentLeftTwips,
          hangingTwips: current.hangingTwips,
          font: current.font,
        );
      }
    }
    numbering[id] = levels;
  }
  return numbering;
}

Map<int, DocxNumLevel> _levelsOf(XmlElement abstractNum) {
  final levels = <int, DocxNumLevel>{};
  for (final element in childrenNamed(abstractNum, 'lvl')) {
    final ilvl = intAttr(element, 'ilvl');
    final level = _levelOf(element);
    if (ilvl != null && level != null) levels[ilvl] = level;
  }
  return levels;
}

DocxNumLevel? _levelOf(XmlElement? lvl) {
  final numFmt = valOf(lvl, 'numFmt');
  if (numFmt == null || lvl == null) return null;
  final indent = childNamed(childNamed(lvl, 'pPr'), 'ind');
  return DocxNumLevel(
    numFmt: numFmt,
    lvlText: valOf(lvl, 'lvlText') ?? '',
    start: intVal(lvl, 'start') ?? 1,
    indentLeftTwips: intAttr(indent, 'left') ?? intAttr(indent, 'start'),
    hangingTwips: intAttr(indent, 'hanging'),
    font: fontOf(childNamed(childNamed(lvl, 'rPr'), 'rFonts')),
  );
}

/// The theme's two faces: the one body text uses and the one headings use.
({String? minor, String? major}) parseThemeFonts(Archive zip) {
  final root = _rootOf(zip, 'word/theme/theme1.xml');
  final scheme = descendantNamed(root, 'fontScheme');
  if (scheme == null) return (minor: null, major: null);
  String? latinOf(String which) =>
      attr(childNamed(childNamed(scheme, which), 'latin'), 'typeface');
  final minor = latinOf('minorFont');
  final major = latinOf('majorFont');
  return (
    minor: (minor?.isEmpty ?? true) ? null : minor,
    major: (major?.isEmpty ?? true) ? null : major,
  );
}

/// `r:id` → the part it points at, as a full path in the zip.
///
/// Targets in the rels part are relative to the part that owns them, so a
/// document's `media/image1.png` is `word/media/image1.png` in the archive.
Map<String, String> parseRelationships(Archive zip) {
  final root = _rootOf(zip, 'word/_rels/document.xml.rels');
  if (root == null) return const {};
  final targets = <String, String>{};
  for (final element in childrenNamed(root, 'Relationship')) {
    final id = attr(element, 'Id');
    final target = attr(element, 'Target');
    if (id == null || target == null) continue;
    if (attr(element, 'TargetMode') == 'External') {
      targets[id] = target;
      continue;
    }
    targets[id] = target.startsWith('/')
        ? target.substring(1)
        : 'word/${target.replaceAll('../', '')}';
  }
  return targets;
}

XmlElement? _rootOf(Archive zip, String path) {
  final bytes = zip.findFile(path)?.readBytes();
  if (bytes == null) return null;
  try {
    return XmlDocument.parse(
      utf8.decode(bytes, allowMalformed: true),
    ).rootElement;
  } on XmlException {
    return null;
  }
}
