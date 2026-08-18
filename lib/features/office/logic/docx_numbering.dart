/// The numbers and bullets Word draws beside a paragraph, worked out from
/// `numbering.xml`.
///
/// **They are not in the document's text.** A numbered item is a paragraph whose
/// `w:numPr` points at a list definition; the "1." is generated at display time
/// and exists nowhere in the file. So an editor that shows only what is written
/// down shows a numbered section with no numbers — which is exactly what Docs
/// did until this existed.
///
/// That also makes the marker read-only by nature: it is drawn beside the
/// paragraph, never inside the field, so it cannot be typed into and is never
/// written back. The save path never sees it.
library;

import 'package:xml/xml.dart';

/// One level of one list.
class DocxNumLevel {
  const DocxNumLevel({
    required this.numFmt,
    required this.lvlText,
    this.start = 1,
    this.indentLeftTwips,
    this.hangingTwips,
  });

  /// `decimal`, `bullet`, `lowerLetter`, `upperRoman`, …
  final String numFmt;

  /// The marker's template: `%1.`, `%1.%2`, or a literal bullet glyph.
  final String lvlText;

  final int start;

  /// The level's own geometry, for an item that states none of its own.
  final int? indentLeftTwips;

  /// How much room the marker gets — Word's hanging indent.
  final int? hangingTwips;
}

/// Which list a paragraph belongs to, and how deep.
typedef DocxListRef = ({String numId, int ilvl});

/// `numbering.xml` read into numId → (level → definition).
///
/// Two indirections, and both matter: a `w:num` points at a `w:abstractNum`
/// (several lists can share one definition), and a `w:lvlOverride` on the `w:num`
/// can replace a level or restart its counter. A reader that followed only the
/// first numbers a document's second list starting from the first one's count.
Map<String, Map<int, DocxNumLevel>> parseNumbering(XmlElement? root) {
  if (root == null) return const {};
  final abstracts = <String, Map<int, DocxNumLevel>>{};
  for (final element in _children(root, 'abstractNum')) {
    final id = _attr(element, 'abstractNumId');
    if (id != null) abstracts[id] = _levelsOf(element);
  }
  final numbering = <String, Map<int, DocxNumLevel>>{};
  for (final element in _children(root, 'num')) {
    final id = _attr(element, 'numId');
    if (id == null) continue;
    final levels = {...?abstracts[_val(element, 'abstractNumId')]};
    for (final override in _children(element, 'lvlOverride')) {
      final ilvl = _intAttr(override, 'ilvl');
      if (ilvl == null) continue;
      final replacement = _levelOf(_child(override, 'lvl'));
      if (replacement != null) {
        levels[ilvl] = replacement;
        continue;
      }
      final start = _intVal(override, 'startOverride');
      final current = levels[ilvl];
      if (start != null && current != null) {
        levels[ilvl] = DocxNumLevel(
          numFmt: current.numFmt,
          lvlText: current.lvlText,
          start: start,
          indentLeftTwips: current.indentLeftTwips,
          hangingTwips: current.hangingTwips,
        );
      }
    }
    numbering[id] = levels;
  }
  return numbering;
}

/// The marker for each paragraph in [refs] — null where the paragraph isn't in a
/// list.
///
/// Numbering is a *document-wide* count, not a property of a paragraph: the third
/// item needs to know about the first two, and a deeper level restarts every time
/// its parent advances. That state has to be walked once over the whole body,
/// which is why this takes the list and returns a list.
List<String?> listMarkers(
  List<DocxListRef?> refs,
  Map<String, Map<int, DocxNumLevel>> numbering,
) {
  final counters = <String, Map<int, int>>{};
  final markers = <String?>[];
  for (final ref in refs) {
    if (ref == null) {
      markers.add(null);
      continue;
    }
    final levels = numbering[ref.numId];
    final level = levels?[ref.ilvl];
    if (level == null) {
      markers.add('•');
      continue;
    }
    final counts = counters.putIfAbsent(ref.numId, () => {});
    // A level advancing restarts everything under it — Word's rule, and what
    // makes "1.1, 1.2, 2.1" come out right instead of "1.1, 1.2, 2.3".
    counts.removeWhere((ilvl, _) => ilvl > ref.ilvl);
    counts[ref.ilvl] = (counts[ref.ilvl] ?? level.start - 1) + 1;
    markers.add(_markerFor(level, levels!, counts, ref.ilvl));
  }
  return markers;
}

/// The hanging indent a list level asks for, so the marker has room to sit in.
int? hangingOf(
  DocxListRef? ref,
  Map<String, Map<int, DocxNumLevel>> numbering,
) => ref == null ? null : numbering[ref.numId]?[ref.ilvl]?.hangingTwips;

/// The left indent a list level asks for, for an item that states none itself.
int? indentOf(
  DocxListRef? ref,
  Map<String, Map<int, DocxNumLevel>> numbering,
) => ref == null ? null : numbering[ref.numId]?[ref.ilvl]?.indentLeftTwips;

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

/// Word writes bullets as private-use characters in Symbol and Wingdings, so a
/// document's own glyph is unreadable without those fonts installed. Map the
/// handful Word's bullet gallery uses to characters every system has.
String _bulletGlyph(String lvlText) {
  if (lvlText.isEmpty) return '•';
  return switch (lvlText.codeUnitAt(0)) {
    0xF0B7 => '•',
    0xF0A7 => '▪',
    0xF0D8 => '➢',
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

Map<int, DocxNumLevel> _levelsOf(XmlElement abstractNum) {
  final levels = <int, DocxNumLevel>{};
  for (final element in _children(abstractNum, 'lvl')) {
    final ilvl = _intAttr(element, 'ilvl');
    final level = _levelOf(element);
    if (ilvl != null && level != null) levels[ilvl] = level;
  }
  return levels;
}

DocxNumLevel? _levelOf(XmlElement? lvl) {
  if (lvl == null) return null;
  final numFmt = _val(lvl, 'numFmt');
  if (numFmt == null) return null;
  final indent = _child(_child(lvl, 'pPr'), 'ind');
  return DocxNumLevel(
    numFmt: numFmt,
    lvlText: _val(lvl, 'lvlText') ?? '',
    start: _intVal(lvl, 'start') ?? 1,
    indentLeftTwips: _intAttr(indent, 'left') ?? _intAttr(indent, 'start'),
    hangingTwips: _intAttr(indent, 'hanging'),
  );
}

Iterable<XmlElement> _children(XmlElement? parent, String local) =>
    parent == null
    ? const []
    : parent.childElements.where((c) => c.name.local == local);

XmlElement? _child(XmlElement? parent, String local) {
  for (final child in _children(parent, local)) {
    return child;
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
