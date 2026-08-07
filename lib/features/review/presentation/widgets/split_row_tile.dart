import 'package:flutter/material.dart';

import '../../../../shared/code/code_highlight.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../logic/split_diff.dart';
import '../../logic/unified_diff.dart';
import 'diff_row_tile.dart';

/// One row of a side-by-side diff: the line as it was on the left, as it is on
/// the right.
///
/// The halves are equal columns rather than a shared scroll of the unified
/// tile's making — two columns only tell you anything if the same change lines
/// up across them.
class SplitRowTile extends StatefulWidget {
  const SplitRowTile({
    super.key,
    required this.row,
    required this.language,
    this.onComment,
    this.wrap = true,
  });

  final SplitRow row;
  final String language;

  /// Leave a remark on this row's line. Null where there is no line to point
  /// at — see [SplitRow.anchorRow].
  final VoidCallback? onComment;

  final bool wrap;

  @override
  State<SplitRowTile> createState() => _SplitRowTileState();
}

class _SplitRowTileState extends State<SplitRowTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final row = widget.row;
    final note = row.note;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // The two halves have to be the same height or the empty one stops
      // covering its side of the row — which is the mark that says "nothing
      // here". `IntrinsicHeight` costs a second layout pass, paid only for the
      // rows actually on screen because the list builds lazily.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: note != null
              // Git's aside is about the file, not about one side of it.
              ? [
                  Expanded(
                    child: _Half(
                      row: note,
                      language: widget.language,
                      wrap: widget.wrap,
                      side: _Side.before,
                      onComment: null,
                    ),
                  ),
                ]
              : [
                  Expanded(
                    child: _Half(
                      row: row.before,
                      language: widget.language,
                      wrap: widget.wrap,
                      side: _Side.before,
                      onComment: null,
                    ),
                  ),
                  VerticalDivider(width: 1, color: AppPalette.divider),
                  Expanded(
                    child: _Half(
                      row: row.after,
                      language: widget.language,
                      wrap: widget.wrap,
                      side: _Side.after,
                      // Offered on the side the comment will name, so the `+`
                      // is next to the line the assistant will be sent to.
                      onComment: _hovered ? widget.onComment : null,
                    ),
                  ),
                ],
        ),
      ),
    );
  }
}

/// Which file a column is showing.
enum _Side { before, after }

/// One column of one row — or the flat fill that stands for "nothing here",
/// which is what makes an added line read as an addition and not a move.
class _Half extends StatelessWidget {
  const _Half({
    required this.row,
    required this.language,
    required this.wrap,
    required this.side,
    required this.onComment,
  });

  final DiffRow? row;
  final String language;
  final bool wrap;
  final _Side side;
  final VoidCallback? onComment;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final line = row;
    if (line == null) return ColoredBox(color: AppGlass.rowFill);

    final theme = Theme.of(context);
    final (background, ink) = switch (line.kind) {
      DiffRowKind.added => (
        AppPalette.online.withValues(alpha: 0.13),
        AppPalette.textPrimary,
      ),
      DiffRowKind.removed => (
        theme.colorScheme.error.withValues(alpha: 0.11),
        AppPalette.textPrimary,
      ),
      DiffRowKind.context => (Colors.transparent, AppPalette.textSecondary),
      DiffRowKind.note => (Colors.transparent, AppPalette.textFaint),
    };
    // A context line is the same on both sides, so only the changed halves are
    // tinted — tinting both would paint the whole file.
    final fill = line.kind == DiffRowKind.context
        ? Colors.transparent
        : background;
    final number = side == _Side.before ? line.oldLine : line.newLine;

    return ColoredBox(
      color: fill,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: DiffRowTile.gutterWidth,
            child: onComment == null
                ? Padding(
                    padding: const EdgeInsets.only(left: 4, right: 8),
                    child: Text(
                      '${number ?? ''}',
                      textAlign: TextAlign.right,
                      style: AppFont.codeStyle(
                        color: AppPalette.textFaint,
                        scale: 0.9,
                        height: 1.5,
                      ),
                    ),
                  )
                : DiffCommentButton(onPressed: onComment!),
          ),
          Expanded(
            child: _Text(row: line, language: language, ink: ink, wrap: wrap),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// The line itself, coloured by the language where we have a grammar.
class _Text extends StatelessWidget {
  const _Text({
    required this.row,
    required this.language,
    required this.ink,
    required this.wrap,
  });

  final DiffRow row;
  final String language;
  final Color ink;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final base = AppFont.codeStyle(color: ink, height: 1.5);
    final overflow = wrap ? TextOverflow.clip : TextOverflow.visible;
    final spans = row.kind == DiffRowKind.note || language.isEmpty
        ? null
        : CodeHighlight.spans(
            code: row.text,
            language: language,
            base: base,
            brightness: Theme.of(context).brightness,
          );
    if (spans == null) {
      return Text(row.text, style: base, softWrap: wrap, overflow: overflow);
    }
    return Text.rich(spans, style: base, softWrap: wrap, overflow: overflow);
  }
}
