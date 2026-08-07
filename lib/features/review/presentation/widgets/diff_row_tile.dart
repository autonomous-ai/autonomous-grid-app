import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/code/code_highlight.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../logic/unified_diff.dart';

/// One line of a file's diff: its line number, whether it came or went, and the
/// line itself.
///
/// Lines *wrap* rather than scrolling sideways. The panel is 420–760px wide, and
/// a diff you have to drag horizontally — one row at a time, since each row
/// would carry its own scroll — is unreadable at that width.
class DiffRowTile extends StatefulWidget {
  const DiffRowTile({
    super.key,
    required this.row,
    required this.language,
    this.onComment,
  });

  final DiffRow row;

  /// The file's language, for colouring. Empty when it isn't one we know.
  final String language;

  /// Leave a remark on this line. Null on rows that can't carry one — Git's own
  /// asides have no line number to point at.
  final VoidCallback? onComment;

  /// The line-number column. Fits five digits — a file longer than 99,999 lines
  /// is not one anybody reads in a panel.
  static const double gutterWidth = 38;

  @override
  State<DiffRowTile> createState() => _DiffRowTileState();
}

class _DiffRowTileState extends State<DiffRowTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = widget.row;
    final theme = Theme.of(context);
    final (background, edge, ink, sign) = switch (row.kind) {
      DiffRowKind.added => (
        AppPalette.online.withValues(alpha: 0.13),
        AppPalette.online,
        AppPalette.textPrimary,
        '+',
      ),
      DiffRowKind.removed => (
        theme.colorScheme.error.withValues(alpha: 0.11),
        theme.colorScheme.error,
        AppPalette.textPrimary,
        '−',
      ),
      DiffRowKind.context => (
        Colors.transparent,
        Colors.transparent,
        AppPalette.textSecondary,
        ' ',
      ),
      // Git's own aside about the file, not a line of it.
      DiffRowKind.note => (
        Colors.transparent,
        Colors.transparent,
        AppPalette.textFaint,
        ' ',
      ),
    };

    final comment = widget.onComment;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: background,
          // The edge bar down the changed lines, the way Codex marks them: at a
          // glance it is what separates a run of additions from the context
          // around it, before any colour has been read.
          //
          // A border rather than a sibling box in the row: a box would have to
          // be stretched to the row's height, and a Row that stretches its
          // children has no height of its own to give them inside a lazy list.
          border: Border(left: BorderSide(color: edge, width: 2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: DiffRowTile.gutterWidth,
              child: _hovered && comment != null
                  // In the number's place rather than beside it: a button that
                  // appeared *next* to the line would push every line right as
                  // the pointer moved down the file.
                  ? _CommentButton(onPressed: comment)
                  : Padding(
                      padding: const EdgeInsets.only(left: 4, right: 8),
                      child: Text(
                        '${row.newLine ?? row.oldLine ?? ''}',
                        textAlign: TextAlign.right,
                        style: AppFont.codeStyle(
                          color: AppPalette.textFaint,
                          scale: 0.9,
                          height: 1.5,
                        ),
                      ),
                    ),
            ),
            // The sign carries what the colour carries, for anyone who can't
            // tell the two tints apart (§11).
            SizedBox(
              width: 12,
              child: Text(
                sign,
                style: AppFont.codeStyle(color: ink, height: 1.5),
              ),
            ),
            Expanded(
              child: _Line(row: row, language: widget.language, ink: ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// The `+` that opens a comment on this line.
class _CommentButton extends StatelessWidget {
  const _CommentButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: 'Comment on this line',
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: AppPalette.accent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Icon(
                LucideIcons.plus,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line's text, coloured by the language when we have a grammar for it.
///
/// One line at a time, which is what makes it cheap enough for a four-thousand-
/// row diff. The cost is that a line inside a block comment is coloured as if it
/// stood alone — wrong in a way that misreads as ordinary code, never as a
/// change that isn't there.
class _Line extends StatelessWidget {
  const _Line({required this.row, required this.language, required this.ink});

  final DiffRow row;
  final String language;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final base = AppFont.codeStyle(color: ink, height: 1.5);
    // Note rows are Git talking about the file, not code in it — colouring
    // them as source would be a lie about what they are.
    final spans = row.kind == DiffRowKind.note || language.isEmpty
        ? null
        : CodeHighlight.spans(
            code: row.text,
            language: language,
            base: base,
            brightness: Theme.of(context).brightness,
          );
    if (spans == null) return Text(row.text, style: base);
    return Text.rich(spans, style: base);
  }
}
