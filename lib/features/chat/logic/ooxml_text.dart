/// Reads the text out of the modern Office formats — `.docx`, `.xlsx`, `.pptx`.
///
/// All three are the same trick: a zip of XML. Word keeps its prose in one
/// document part, Excel keeps most cell text in a shared table the sheets index
/// into, and PowerPoint keeps a part per slide. Pure — bytes in, text out — so
/// each format is tested against a hand-built zip rather than against a file
/// someone has to keep in the repo.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Word: `word/document.xml`, one line per paragraph.
String? docxText(Uint8List bytes) {
  final document = _parseXml(_unzip(bytes)?.findFile('word/document.xml'));
  if (document == null) return null;
  return [
    for (final paragraph in document.findAllElements('p', namespaceUri: '*'))
      _paragraphText(paragraph),
  ].join('\n');
}

/// PowerPoint: every slide in order, headed by its number so a model can say
/// which slide a line came from.
String? pptxText(Uint8List bytes) {
  final slides = _numberedParts(bytes, 'ppt/slides/slide');
  if (slides.isEmpty) return null;

  final out = <String>[];
  for (final (number, part) in slides) {
    final xml = _parseXml(part);
    if (xml == null) continue;
    final lines = [
      for (final paragraph in xml.findAllElements('p', namespaceUri: '*'))
        _paragraphText(paragraph),
    ].where((line) => line.trim().isNotEmpty);
    if (lines.isEmpty) continue;
    out.add('--- Slide $number ---');
    out.addAll(lines);
  }
  return out.join('\n');
}

/// Excel: each sheet as tab-separated rows, headed by its name.
///
/// Cell text mostly lives in one shared table rather than in the cells (`t="s"`
/// holds an index into it), so the sheets are worth nothing without
/// `sharedStrings.xml` — which is why it is read first.
String? xlsxText(Uint8List bytes) {
  final archive = _unzip(bytes);
  if (archive == null) return null;
  final shared = _sharedStrings(archive);
  final names = _sheetNames(archive);
  final sheets = _numberedParts(bytes, 'xl/worksheets/sheet', archive: archive);
  if (sheets.isEmpty) return null;

  final out = <String>[];
  for (var i = 0; i < sheets.length; i++) {
    final xml = _parseXml(sheets[i].$2);
    if (xml == null) continue;
    final rows = [
      for (final row in xml.findAllElements('row', namespaceUri: '*'))
        ?_rowText(row, shared),
    ];
    if (rows.isEmpty) continue;
    out.add('--- ${i < names.length ? names[i] : 'Sheet ${i + 1}'} ---');
    out.addAll(rows);
  }
  return out.join('\n');
}

/// One row as tab-separated cells, or null when the row holds nothing.
String? _rowText(XmlElement row, List<String> shared) {
  final cells = [
    for (final cell in row.findAllElements('c', namespaceUri: '*'))
      _cellText(cell, shared),
  ];
  // Trailing empties are the sheet's own padding, not data.
  while (cells.isNotEmpty && cells.last.isEmpty) {
    cells.removeLast();
  }
  return cells.isEmpty ? null : cells.join('\t');
}

/// One `<w:p>` / `<a:p>` as a line: its runs of text, with tabs and line breaks
/// kept where the document put them.
String _paragraphText(XmlElement paragraph) {
  final buffer = StringBuffer();
  for (final node in paragraph.descendants.whereType<XmlElement>()) {
    switch (node.name.local) {
      case 't':
        buffer.write(node.innerText);
      case 'tab':
        buffer.write('\t');
      case 'br':
        buffer.write('\n');
    }
  }
  return buffer.toString();
}

/// One spreadsheet cell: a shared-table lookup (`t="s"`), an inline string, or
/// the literal value — the empty string when the cell holds nothing.
String _cellText(XmlElement cell, List<String> shared) {
  final type = cell.getAttribute('t');
  if (type == 's') {
    final index = int.tryParse(_childText(cell, 'v') ?? '');
    if (index == null || index < 0 || index >= shared.length) return '';
    return shared[index];
  }
  if (type == 'inlineStr') {
    return [
      for (final t in cell.findAllElements('t', namespaceUri: '*')) t.innerText,
    ].join();
  }
  return _childText(cell, 'v') ?? '';
}

/// The workbook's shared string table, in index order.
List<String> _sharedStrings(Archive archive) {
  final xml = _parseXml(archive.findFile('xl/sharedStrings.xml'));
  if (xml == null) return const [];
  return [
    for (final si in xml.findAllElements('si', namespaceUri: '*'))
      [
        for (final t in si.findAllElements('t', namespaceUri: '*')) t.innerText,
      ].join(),
  ];
}

/// The sheet names the user gave their tabs, in the order the workbook lists
/// them — so a row of numbers arrives under "Q3 revenue" instead of "Sheet 2".
List<String> _sheetNames(Archive archive) {
  final xml = _parseXml(archive.findFile('xl/workbook.xml'));
  if (xml == null) return const [];
  return [
    for (final sheet in xml.findAllElements('sheet', namespaceUri: '*'))
      ?sheet.getAttribute('name'),
  ];
}

/// The `<prefix>N.xml` parts of the zip, in **numeric** order — `slide10` comes
/// after `slide2`, which the zip's own alphabetical order gets backwards.
List<(int, ArchiveFile)> _numberedParts(
  Uint8List bytes,
  String prefix, {
  Archive? archive,
}) {
  final zip = archive ?? _unzip(bytes);
  if (zip == null) return const [];
  final parts = <(int, ArchiveFile)>[
    for (final file in zip.files)
      if (file.isFile)
        if (_partNumber(file.name, prefix) case final number?) (number, file),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return parts;
}

int? _partNumber(String path, String prefix) {
  if (!path.startsWith(prefix) || !path.endsWith('.xml')) return null;
  return int.tryParse(
    path.substring(prefix.length, path.length - '.xml'.length),
  );
}

String? _childText(XmlElement element, String name) {
  for (final child in element.childElements) {
    if (child.name.local == name) return child.innerText;
  }
  return null;
}

XmlDocument? _parseXml(ArchiveFile? part) {
  final bytes = part?.readBytes();
  if (bytes == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } on XmlException {
    return null;
  }
}

/// The zip inside an Office file — null when it isn't one (a `.docx` that is
/// really something else, or a file that got truncated in transit).
Archive? _unzip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object {
    return null;
  }
}
