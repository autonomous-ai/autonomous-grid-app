import 'package:flutter/material.dart';

import '../../logic/docx/docx_model.dart';
import '../../logic/docx/docx_resolve.dart';
import 'docx_spans.dart';
import 'docx_table_view.dart';

/// One block of the document, drawn.
///
/// The formatting is already resolved by the time it gets here — this widget's
/// only job is to turn resolved numbers into geometry, and the geometry that
/// isn't obvious is Word's indent model:
///
/// ```
///  |<- indentLeft ->|                                    |<- indentRight ->|
///                   ↳ first line starts here + firstLine (negative = hangs)
/// ```
///
/// A list item is that same model with the marker sitting in the hang.
class DocxBlockView extends StatelessWidget {
  const DocxBlockView({
    super.key,
    required this.doc,
    required this.block,
    required this.markers,
    required this.availableWidth,
    this.inTable = false,
  });

  final ParsedDocx doc;
  final DocxBlock block;

  /// Markers for every block in the document, by index — a list item's number is
  /// a document-wide count, so it cannot be worked out here.
  final List<String?> markers;

  /// The width this block has to lay out in, which a table needs to know to fit
  /// its columns.
  final double availableWidth;

  /// Inside a table cell, where a paragraph's own space-before/after is
  /// suppressed: Word's table styles zero it, and honouring it here is what makes
  /// every cell of a plain table twice as tall as it should be.
  final bool inTable;

  @override
  Widget build(BuildContext context) {
    if (block.hidden) return const SizedBox.shrink();
    if (block.kind == DocxBlockKind.table) {
      final table = block.table;
      if (table == null) return const SizedBox.shrink();
      return DocxTableView(
        doc: doc,
        table: table,
        markers: markers,
        availableWidth: availableWidth,
      );
    }
    if (block.kind == DocxBlockKind.image) return _Image(block: block);

    final para = resolvePara(doc, block);
    final marker = block.docxIndex != null && block.docxIndex! < markers.length
        ? markers[block.docxIndex!]
        : null;
    return Padding(
      padding: EdgeInsets.only(
        top: inTable ? 0 : para.spaceBeforePx,
        bottom: inTable ? 0 : para.spaceAfterPx,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: _shading(para.shadingFill)),
        child: marker != null
            ? _ListItem(doc: doc, block: block, para: para, marker: marker)
            : _Paragraph(doc: doc, block: block, para: para),
      ),
    );
  }

  Color? _shading(String? hex) {
    if (hex == null || hex.length < 6) return null;
    final parsed = int.tryParse(hex.substring(0, 6), radix: 16);
    return parsed == null ? null : Color(0xFF000000 | parsed);
  }
}

/// A run of text: one paragraph, one [Text.rich].
class _Paragraph extends StatelessWidget {
  const _Paragraph({
    required this.doc,
    required this.block,
    required this.para,
  });

  final ParsedDocx doc;
  final DocxBlock block;
  final ResolvedPara para;

  @override
  Widget build(BuildContext context) {
    final spans = runSpans(doc, para, block);
    return Padding(
      padding: EdgeInsets.only(
        left: para.indentLeftPx,
        right: para.indentRightPx,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            // Flutter has no text-indent, so a first-line indent is an empty box
            // at the start of the first line — which is exactly what the indent
            // is. Only for a positive value: a negative one is a hang, and a
            // paragraph with no marker has nothing to put in it.
            if (para.firstLinePx > 0)
              WidgetSpan(child: SizedBox(width: para.firstLinePx)),
            ...spans,
          ],
        ),
        textAlign: textAlignOf(para.align),
        // An empty paragraph is a blank line in Word, and it has a height — its
        // own font's. Without a strut Flutter would draw nothing at all and the
        // document would lose every gap the author typed.
        strutStyle: StrutStyle(
          fontSize: para.base.fontSizePx,
          height: para.lineHeight,
          forceStrutHeight: spans.isEmpty,
        ),
      ),
    );
  }
}

/// A numbered or bulleted item: the marker in the hang, the text beside it.
class _ListItem extends StatelessWidget {
  const _ListItem({
    required this.doc,
    required this.block,
    required this.para,
    required this.marker,
  });

  final ParsedDocx doc;
  final DocxBlock block;
  final ResolvedPara para;
  final String marker;

  @override
  Widget build(BuildContext context) {
    // Word measures the marker's column from the hang. A level with no hanging
    // indent still needs room, or the number and the text touch.
    final hang = para.firstLinePx < 0 ? -para.firstLinePx : 18.0;
    final textStyle = runTextStyle(para.base, para);
    return Padding(
      padding: EdgeInsets.only(
        // The marker starts at indentLeft + firstLine, which for a hang is to
        // the left of the text — so the row begins there and the marker box
        // takes it back.
        left: (para.indentLeftPx - hang).clamp(0.0, double.infinity),
        right: para.indentRightPx,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: hang,
            child: Text(marker, style: textStyle),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: runSpans(doc, para, block)),
              textAlign: textAlignOf(para.align),
              strutStyle: StrutStyle(
                fontSize: para.base.fontSizePx,
                height: para.lineHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture on its own line.
class _Image extends StatelessWidget {
  const _Image({required this.block});

  final DocxBlock block;

  @override
  Widget build(BuildContext context) {
    final image = block.image;
    if (image == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: switch (image.align) {
          DocxAlign.center => Alignment.center,
          DocxAlign.right => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: Image.memory(
          image.bytes,
          width: image.widthPx,
          height: image.heightPx,
          // The size Word was told to draw it at is the size it prints at, so a
          // picture that doesn't fit the column is scaled, not cropped.
          fit: BoxFit.contain,
          // A format Flutter can't decode (an EMF or WMF from an old document)
          // leaves a frame rather than a red exception box, so the document is
          // still readable around it.
          errorBuilder: (context, _, _) =>
              _BrokenImage(width: image.widthPx, height: image.heightPx),
        ),
      ),
    );
  }
}

/// A picture this build cannot decode, as an honest empty frame.
class _BrokenImage extends StatelessWidget {
  const _BrokenImage({this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => Container(
    width: width ?? 120,
    height: height ?? 90,
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0x33000000)),
      color: const Color(0x08000000),
    ),
    alignment: Alignment.center,
    child: const Text(
      'Picture',
      style: TextStyle(fontSize: 11, color: Color(0x66000000)),
    ),
  );
}
