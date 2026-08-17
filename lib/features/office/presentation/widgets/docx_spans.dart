import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/docx/docx_model.dart';
import '../../logic/docx/docx_resolve.dart';

/// Turning a paragraph's runs into the spans Flutter lays out.
///
/// The resolved formatting arrives already decided (`docx_resolve.dart`); this
/// only translates it — OOXML's names for things into Flutter's. Where the two
/// don't line up the compromise is stated at the line, not smoothed over.
List<InlineSpan> runSpans(ParsedDocx doc, ResolvedPara para, DocxBlock block) =>
    [
      for (final run in block.runs)
        if (run.text.isNotEmpty) _span(resolveRun(doc, para, run), run, para),
    ];

InlineSpan _span(ResolvedRun style, DocxRun run, ResolvedPara para) =>
    TextSpan(text: run.text, style: runTextStyle(style, para));

/// One run's [TextStyle].
TextStyle runTextStyle(ResolvedRun run, ResolvedPara para) {
  final superscript = run.vertAlign == 'superscript';
  final subscript = run.vertAlign == 'subscript';
  return TextStyle(
    // The document's own ink, never the app's: a paragraph with no colour of its
    // own is black on paper, because that is what will print.
    color:
        _hex(run.colorHex) ??
        (run.link != null ? _linkBlue : AppPalette.paperInk),
    fontSize: superscript || subscript ? run.fontSizePx * 0.66 : run.fontSizePx,
    // Word's bold is heavier than Flutter's w600; w700 is what a Word document
    // looks like beside its PDF.
    fontWeight: run.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
    decoration: _decoration(run),
    decorationColor: _hex(run.colorHex),
    fontFamily: run.fontFamily,
    // The line height belongs to the paragraph, not the run: Word gives every
    // line in a paragraph the same height, so a small run inside a large
    // paragraph must not shrink its line.
    height: para.lineHeight,
    backgroundColor: _highlight(run.highlight) ?? _hex(run.shading),
    // Real super/subscript when the face has the feature; the smaller size above
    // is what carries it when the face does not, which reads as raised text
    // rather than as nothing.
    fontFeatures: [
      if (superscript) const FontFeature.superscripts(),
      if (subscript) const FontFeature.subscripts(),
    ],
  );
}

TextDecoration? _decoration(ResolvedRun run) {
  final lines = [
    if (run.underline || run.link != null) TextDecoration.underline,
    if (run.strike) TextDecoration.lineThrough,
  ];
  return lines.isEmpty ? null : TextDecoration.combine(lines);
}

/// Word's link blue, not the app's accent: the document is what is being shown,
/// and a hyperlink in a Word file is this colour.
const _linkBlue = Color(0xFF0563C1);

Color? _hex(String? value) {
  if (value == null || value.length < 6) return null;
  final parsed = int.tryParse(value.substring(0, 6), radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}

/// `w:highlight` is a fixed set of names — Word's marker pens — rather than a
/// colour value, so it needs the table Word draws them from.
Color? _highlight(String? name) => switch (name) {
  'yellow' => const Color(0xFFFFFF00),
  'green' => const Color(0xFF00FF00),
  'cyan' => const Color(0xFF00FFFF),
  'magenta' => const Color(0xFFFF00FF),
  'blue' => const Color(0xFF0000FF),
  'red' => const Color(0xFFFF0000),
  'darkBlue' => const Color(0xFF000080),
  'darkCyan' => const Color(0xFF008080),
  'darkGreen' => const Color(0xFF008000),
  'darkMagenta' => const Color(0xFF800080),
  'darkRed' => const Color(0xFF800000),
  'darkYellow' => const Color(0xFF808000),
  'darkGray' => const Color(0xFF808080),
  'lightGray' => const Color(0xFFC0C0C0),
  'black' => const Color(0xFF000000),
  'white' => const Color(0xFFFFFFFF),
  _ => null,
};

TextAlign textAlignOf(DocxAlign align) => switch (align) {
  DocxAlign.left => TextAlign.left,
  DocxAlign.center => TextAlign.center,
  DocxAlign.right => TextAlign.right,
  DocxAlign.justify => TextAlign.justify,
};
