// Why Docs patches `.docx` bytes instead of reading a document into a library's
// model and writing it back out.
//
//   dart run tool/docx_library_probe.dart <file.docx>
//
// `docx_creator` is already a dependency — Docs uses it to make blank files —
// and its page advertises "Load → Parse → Modify → Export" with "all
// formatting, lists, tables, shapes preserved". If that held, most of
// `docx_edit.dart` and `docx_style_write.dart` would be code this app does not
// need to own. It does not hold. Measured 2026-08-19 on a real 630KB student
// report (`DocxReader.load` → `DocxExporter`, package 1.3.2):
//
//   <w:p>       248 -> 232     16 paragraphs gone
//   <w:r>       280 -> 191     89 runs gone
//   <w:tc>      189 -> 173     16 table cells gone
//   <w:br>       24 ->  10     14 soft line breaks gone
//   zip parts    16 ->  16     word/footer2.xml dropped
//
// Tables, rows, pictures and numbering survive by count; the words inside them
// do not. Silent loss on somebody's own file is the one failure this feature
// cannot ship, so the reader is not used for editing and the patch stays. (The
// package's `src/editor/` is a *PDF* element tree and isn't exported, so this
// round trip is the only path it offers.)
//
// The same file through this app's own path, on the same day and measured the
// same way — with **every** paragraph centred and bolded, the most one save can
// be asked to do:
//
//   <w:p> 248 -> 248, <w:r> 280 -> 280, <w:tc> 189 -> 189, <w:br> 24 -> 24,
//   zip parts 16 -> 16, none lost, none gained.
//
// That is the whole argument for `docx_style_write.dart` existing: it reaches
// into the `w:pPr` a paragraph already has instead of rebuilding it, so
// formatting a document costs nothing that was in it.
//
// Re-run this before believing a newer version of the package has fixed its
// half. Compares the zip parts and the body's element counts, because that is
// what "preserved" has to mean for a document somebody wrote.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:grid_app/features/office/logic/docx_edit.dart';
import 'package:grid_app/features/office/logic/docx_format.dart';
import 'package:grid_app/features/office/logic/docx_paragraph_style.dart';

int _count(String xml, String tag) =>
    RegExp('<w:$tag[ />]').allMatches(xml).length;

Future<void> main(List<String> args) async {
  final path = args.isEmpty ? null : args.first;
  if (path == null) {
    stdout.writeln('usage: dart run tool/docx_library_probe.dart <file.docx>');
    return;
  }
  final before = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final out = '${Directory.systemTemp.path}/grid-library-probe.docx';

  try {
    final document = await DocxReader.load(path);
    await DocxExporter().exportToFile(document, out);
  } on Object catch (error) {
    stdout.writeln('LOAD/EXPORT THREW: $error');
    return;
  }

  await _report('docx_creator round trip', before, out);
  await File(out).delete();

  // The same file through this app's own path, measured the same way — because
  // "the library loses things" is only half an argument. Every paragraph is
  // centred and set bold, which is the most the toolbar can ask of one save.
  final docx = DocxFile.open(await File(path).readAsBytes());
  if (docx == null) {
    stdout.writeln('\nGrid could not open it either.');
    return;
  }
  final ours = '${Directory.systemTemp.path}/grid-own-probe.docx';
  await File(ours).writeAsBytes(
    docx.save(
      docx.lines,
      styles: List.filled(
        docx.lines.length,
        const DocxParagraphStyle(align: DocxTextAlign.center, bold: true),
      ),
    ),
  );
  stdout.writeln('');
  await _report(
    "Grid's patch, every paragraph centred and bolded",
    before,
    ours,
  );
  await File(ours).delete();
}

Future<void> _report(String what, Archive before, String outPath) async {
  final after = ZipDecoder().decodeBytes(await File(outPath).readAsBytes());
  final beforeParts = {for (final f in before.files) f.name};
  final afterParts = {for (final f in after.files) f.name};
  stdout.writeln('== $what');

  String body(Archive zip) => String.fromCharCodes(
    zip.findFile('word/document.xml')?.readBytes() ?? [],
  );
  final b = body(before);
  final a = body(after);

  // Uncompressed both sides. Zip sizes differ by how hard each writer squeezed,
  // which says nothing about what survived.
  stdout.writeln('content      ${_sizeOf(before)} -> ${_sizeOf(after)}');
  stdout.writeln('zip parts    ${beforeParts.length} -> ${afterParts.length}');
  stdout.writeln('  lost:      ${beforeParts.difference(afterParts).toList()}');
  stdout.writeln('  gained:    ${afterParts.difference(beforeParts).toList()}');
  for (final tag in ['p', 'r', 'tbl', 'tr', 'tc', 'drawing', 'numPr', 'br']) {
    final name = '<w:$tag>'.padRight(13);
    stdout.writeln('$name${_count(b, tag)} -> ${_count(a, tag)}');
  }
}

int _sizeOf(Archive zip) => zip.files.fold<int>(0, (sum, f) => sum + f.size);
