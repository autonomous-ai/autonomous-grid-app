import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/review_file.dart';

/// The one-letter badge that says what happened to a file.
///
/// A letter rather than a colour alone: colour-blind users get the same
/// information as everyone else, and the same badge has to read at 12px in a
/// narrow panel (§11).
class ReviewMark extends StatelessWidget {
  const ReviewMark({super.key, required this.kind});

  final ReviewFileKind kind;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final (letter, colour) = markFor(context, kind);
    return Tooltip(
      message: markLabel(kind),
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          letter,
          style: AppFont.codeStyle(
            color: colour,
            scale: 0.86,
            fontWeight: AppFont.semibold,
          ),
        ),
      ),
    );
  }
}

/// The letter and colour for [kind]. Shared so the list and a file's own header
/// can never disagree about what a change is.
(String, Color) markFor(BuildContext context, ReviewFileKind kind) =>
    switch (kind) {
      ReviewFileKind.added => ('A', AppPalette.online),
      ReviewFileKind.untracked => ('U', AppPalette.online),
      ReviewFileKind.modified => ('M', AppPalette.warn),
      ReviewFileKind.deleted => ('D', Theme.of(context).colorScheme.error),
      ReviewFileKind.renamed => ('R', AppPalette.accentOnSurface),
      ReviewFileKind.conflicted => ('!', Theme.of(context).colorScheme.error),
    };

/// What the letter means, spelled out — the tooltip, and the word the rest of
/// the surface uses for the same thing.
String markLabel(ReviewFileKind kind) => switch (kind) {
  ReviewFileKind.added => 'Added',
  ReviewFileKind.untracked => 'New file, not tracked by Git yet',
  ReviewFileKind.modified => 'Changed',
  ReviewFileKind.deleted => 'Deleted',
  ReviewFileKind.renamed => 'Moved',
  ReviewFileKind.conflicted => 'Half-merged, still has conflicts',
};

/// `+9 −2` for a file or a whole change set, or "Binary" where counting lines
/// says nothing. Empty when nothing changed.
class ChangeCount extends StatelessWidget {
  const ChangeCount({
    super.key,
    required this.added,
    required this.removed,
    this.binary = false,
  });

  final int added;
  final int removed;
  final bool binary;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (binary) {
      return Text(
        'Binary',
        style: AppFont.codeStyle(color: AppPalette.textFaint, scale: 0.88),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          Text(
            '+$added',
            style: AppFont.codeStyle(color: AppPalette.online, scale: 0.88),
          ),
        if (added > 0 && removed > 0) const SizedBox(width: 6),
        if (removed > 0)
          Text(
            // A minus sign, not a hyphen: beside `+9` a hyphen reads as a
            // dash between two numbers.
            '−$removed',
            style: AppFont.codeStyle(
              color: Theme.of(context).colorScheme.error,
              scale: 0.88,
            ),
          ),
      ],
    );
  }
}
