// Manual probe: reads a real .docx through the display parser and prints what it
// found — block kinds, the resolved formatting of the first paragraphs, tables,
// pictures, list markers. Run:
//   dart run tool/docx_layout_check.dart /path/to/file.docx
// Read-only; it never writes to the file. Not a unit test (§8 keeps test/ to the
// grid and the agents) — this is for checking the reader against a document Word
// made, which is the only thing that proves it.
import 'dart:io';

import 'package:grid_app/features/office/logic/docx/docx_model.dart';
import 'package:grid_app/features/office/logic/docx/docx_parse.dart';
import 'package:grid_app/features/office/logic/docx/docx_resolve.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/docx_layout_check.dart <file.docx>');
    exit(2);
  }
  final bytes = await File(args.first).readAsBytes();
  final doc = parseDocxLayout(bytes);
  if (doc == null) {
    stderr.writeln('not a readable .docx');
    exit(1);
  }

  final counts = <DocxBlockKind, int>{};
  for (final block in doc.blocks) {
    counts[block.kind] = (counts[block.kind] ?? 0) + 1;
  }
  stdout.writeln('blocks: ${doc.blocks.length}');
  for (final entry in counts.entries) {
    stdout.writeln('  ${entry.key.name}: ${entry.value}');
  }
  stdout.writeln('styles: ${doc.styles.length}, lists: ${doc.numbering.length}');
  stdout.writeln(
    'page: ${doc.section.pageWidthPx.toStringAsFixed(0)}x'
    '${doc.section.pageHeightPx.toStringAsFixed(0)}px, '
    'body ${doc.section.bodyWidthPx.toStringAsFixed(0)}px, '
    'margins ${doc.section.marginLeftPx.toStringAsFixed(0)}/'
    '${doc.section.marginTopPx.toStringAsFixed(0)}',
  );
  stdout.writeln(
    'docDefaults: ${doc.docDefaults.font} '
    '${(doc.docDefaults.sizeHalfPoints ?? 0) / 2}pt '
    'line=${doc.docDefaults.lineTwips} ${doc.docDefaults.lineRule?.name}',
  );
  stdout.writeln('theme: minor=${doc.themeMinorFont} major=${doc.themeMajorFont}');

  stdout.writeln('\n-- first 12 drawable blocks --');
  var shown = 0;
  for (var i = 0; i < doc.blocks.length && shown < 12; i++) {
    final block = doc.blocks[i];
    if (block.hidden) continue;
    if (block.kind == DocxBlockKind.table) {
      final table = block.table!;
      stdout.writeln(
        '[$i] table ${table.rows.length}x${table.gridTwips.length} '
        'style=${table.styleId} border=${table.borders?.top?.widthPx} '
        'first cell="${_clip(table.rows.first.cells.first.blocks.map((b) => b.text).join())}"',
      );
      shown++;
      continue;
    }
    if (block.kind == DocxBlockKind.image) {
      stdout.writeln(
        '[$i] image ${block.image!.bytes.length}B '
        '${block.image!.widthPx?.toStringAsFixed(0)}x'
        '${block.image!.heightPx?.toStringAsFixed(0)}px',
      );
      shown++;
      continue;
    }
    if (block.text.trim().isEmpty) continue;
    final para = resolvePara(doc, block);
    final marker = doc.markers[i];
    stdout.writeln(
      '[$i] ${block.kind.name}${block.level == null ? '' : ' h${block.level}'} '
      'style=${block.styleId} align=${para.align.name} '
      'line=${para.lineHeight.toStringAsFixed(2)} '
      'before=${para.spaceBeforePx.toStringAsFixed(0)} '
      'after=${para.spaceAfterPx.toStringAsFixed(0)} '
      'indent=${para.indentLeftPx.toStringAsFixed(0)}/'
      '${para.firstLinePx.toStringAsFixed(0)} '
      'font=${para.base.fontFamily} '
      '${para.base.fontSizePx.toStringAsFixed(1)}px '
      '${marker == null ? '' : 'marker="$marker" '}'
      '"${_clip(block.text)}"',
    );
    shown++;
  }

  stdout.writeln('\n-- runs of the first paragraph with mixed formatting --');
  for (final block in doc.blocks) {
    if (block.runs.length < 2) continue;
    final para = resolvePara(doc, block);
    stdout.writeln('"${_clip(block.text)}"');
    for (final run in block.runs) {
      final resolved = resolveRun(doc, para, run);
      stdout.writeln(
        '   b=${resolved.bold} i=${resolved.italic} u=${resolved.underline} '
        'size=${resolved.fontSizePx.toStringAsFixed(1)} '
        'color=${resolved.colorHex} font=${resolved.fontFamily} '
        'hl=${resolved.highlight} link=${resolved.link} '
        '"${_clip(run.text, 30)}"',
      );
    }
    break;
  }

  final markers = doc.markers.where((m) => m != null).toList();
  stdout.writeln('\nlist markers found: ${markers.length}');
  stdout.writeln('  ${markers.take(12).join('  ')}');
}

String _clip(String text, [int max = 46]) {
  final flat = text.replaceAll('\n', '⏎').replaceAll('\t', '→');
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}
