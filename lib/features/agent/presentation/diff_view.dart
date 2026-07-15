import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/edit_diff.dart';

/// A monospace, `+`/`-` rendering of an edit's [DiffLine]s.
///
/// The shared way the app shows a file change — both the permission card (before
/// an edit) and the changes review (after) draw the same picture, so approving
/// and undoing read as the same thing.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (final line in lines) _DiffRow(line: line)],
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final (prefix, color) = switch (line.kind) {
      DiffLineKind.added => ('+', AppPalette.online),
      DiffLineKind.removed => ('-', Theme.of(context).colorScheme.error),
      DiffLineKind.context => (' ', AppPalette.textFaint),
    };
    return Text(
      '$prefix ${line.text}',
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.5,
        color: color,
      ),
    );
  }
}
