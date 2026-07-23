import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../shared/theme/app_theme.dart';

/// The app's markdown stylesheet for a chat turn.
///
/// `flutter_markdown_plus` derives its default sheet from the ambient Material
/// theme, which gets the type ramp roughly right but not the surfaces: block
/// code and tables come back with Material's own fills and a full-strength grid.
/// Everything visual is pinned here so a reply reads like the rest of the app.
MarkdownStyleSheet buildMarkdownStyleSheet(
  BuildContext context, {
  required Color textColor,
}) {
  final theme = Theme.of(context);
  // Body copy gets more leading than the app's default 1.34: that figure is
  // tuned for single-line UI labels, while an answer is read continuously.
  final body = theme.textTheme.bodyMedium!.copyWith(
    color: textColor,
    height: 1.55,
  );

  // Headings inside an answer sit *within* body copy, so the ramp starts below
  // the page-level headline sizes — an "##" shouldn't tower over the paragraph
  // it introduces. All w600, per the design system.
  TextStyle heading(double size) =>
      body.copyWith(fontSize: size, fontWeight: FontWeight.w600, height: 1.3);

  final mono = TextStyle(
    fontFamily: AppFont.mono,
    fontFamilyFallback: AppFont.monoFallback,
    fontSize: 12.5,
    height: 1.5,
    color: textColor,
  );

  return MarkdownStyleSheet(
    p: body,
    a: TextStyle(
      // The on-surface accent, not AppPalette.accent: #2F5BEA reaches only
      // 2.6:1 on the dark pane, so links there take the lifted variant.
      color: AppPalette.accentOnSurface,
      decoration: TextDecoration.underline,
      decorationColor: AppPalette.accentOnSurface,
    ),
    h1: heading(22),
    h2: heading(17),
    h3: heading(15.5),
    h4: heading(14.5),
    h5: heading(13.5),
    h6: heading(13.5),
    em: body.copyWith(fontStyle: FontStyle.italic),
    strong: body.copyWith(fontWeight: FontWeight.w600),
    del: body.copyWith(decoration: TextDecoration.lineThrough),
    // Inline code: the recessed fill, so a `token` reads as a chip rather than
    // as differently-coloured prose.
    code: mono.copyWith(fontSize: 12.5, backgroundColor: AppCard.inset),
    codeblockDecoration: BoxDecoration(
      color: AppCard.inset,
      borderRadius: BorderRadius.circular(12),
    ),
    codeblockPadding: const EdgeInsets.all(14),
    blockquote: body.copyWith(color: AppPalette.textSecondary),
    blockquoteDecoration: BoxDecoration(
      color: AppCard.inset,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    // A `---` a model wrote mid-answer: a paragraph break, not a rule that
    // outweighs the text around it.
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppPalette.divider)),
    ),
    // Tables are separated by hairlines, never a drawn grid — rule 1. The
    // package's default is a full border on every cell.
    tableBorder: TableBorder(
      horizontalInside: BorderSide(color: AppPalette.divider),
    ),
    tableHead: body.copyWith(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      color: AppPalette.textSecondary,
    ),
    // Header sits on the same axis as the cells under it. The package centres
    // headers by default, which leaves a left-aligned column of values hanging
    // off a centred label — the "#" column reads as if it belongs to neither.
    tableHeadAlign: TextAlign.left,
    // Columns take the *smaller* of "as wide as their content" and "an even
    // share of the table". Two failure modes to stay between: the package
    // default (`FlexColumnWidth`) splits evenly, giving a one-digit "#" column
    // the same width as a sentence of notes and wrapping hotel names over three
    // lines; plain `IntrinsicColumnWidth` fixes that but has no ceiling, and a
    // cell holding a long URL measured 1776px against a 760px column.
    tableColumnWidth: const MinColumnWidth(
      IntrinsicColumnWidth(),
      FlexColumnWidth(),
    ),
    tableBody: body.copyWith(fontSize: 13.5, height: 1.45),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    tableHeadCellsPadding: const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 9,
    ),
    // Block spacing: the gap above a heading is larger than the gap below it,
    // so a heading binds to the text it introduces instead of floating between
    // two blocks.
    h1Padding: const EdgeInsets.only(top: 20, bottom: 6),
    h2Padding: const EdgeInsets.only(top: 18, bottom: 6),
    h3Padding: const EdgeInsets.only(top: 16, bottom: 4),
    blockSpacing: 12,
    listIndent: 22,
    listBullet: body,
  );
}
