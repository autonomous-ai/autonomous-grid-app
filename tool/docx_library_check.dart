// Manual probe: reads a real .docx through `docx_creator` — the parser behind the
// Formatted view — and prints what it found. Run:
//   dart run tool/docx_library_check.dart /path/to/file.docx
//
// Two things it proves, neither of which a compile proves:
//  - the package works against `xml: ^7.0.1`, which the app overrides it onto
//    (it declares ^6.6.1; see the note in pubspec.yaml);
//  - it actually reads a document Word made, with its sections, tables and
//    pictures, rather than returning an empty shell.
// Read-only. Not a unit test — §8 keeps test/ to the grid and the agents.
import 'dart:io';

import 'package:docx_creator/docx_creator.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/docx_library_check.dart <file.docx>');
    exit(2);
  }
  final bytes = await File(args.first).readAsBytes();
  final document = await DocxReader.loadFromBytes(bytes);

  final counts = <String, int>{};
  for (final node in document.elements) {
    final key = node.runtimeType.toString();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  stdout.writeln('elements: ${document.elements.length}');
  for (final entry in counts.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
  stdout.writeln(
    'section: ${document.section}\n'
    'styles.xml read: ${document.stylesXml != null}, '
    'numbering.xml read: ${document.numberingXml != null}, '
    'fonts: ${document.fonts.length}, '
    'footnotes: ${document.footnotes?.length ?? 0}',
  );

  stdout.writeln('\n-- first 12 paragraphs, as the library resolved them --');
  var shown = 0;
  for (final node in document.elements) {
    if (shown >= 12) break;
    if (node is DocxTable) {
      stdout.writeln('TABLE rows=${node.rows.length}');
      shown++;
      continue;
    }
    if (node is! DocxParagraph) {
      stdout.writeln('${node.runtimeType}');
      shown++;
      continue;
    }
    final text = node.children
        .map((child) => child is DocxText ? child.content : '')
        .join();
    if (text.trim().isEmpty) continue;
    stdout.writeln(
      'style=${node.styleId ?? '-'} align=${node.align.name} '
      'line=${node.lineSpacing}/${node.lineRule} '
      'before=${node.spacingBefore} after=${node.spacingAfter} '
      'indL=${node.indentLeft} runs=${node.children.length} '
      '"${_clip(text)}"',
    );
    shown++;
  }
}

String _clip(String text, [int max = 40]) {
  final flat = text.replaceAll('\n', '⏎').replaceAll('\t', '→');
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}
