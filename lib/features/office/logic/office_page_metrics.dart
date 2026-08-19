/// Where the sheet of paper sits, and where its text column sits on it.
///
/// One measurement, used three times: the editor lays the page out by it, the
/// horizontal ruler draws its margins and indent markers against it, and the
/// vertical ruler matches its width. They were the same three numbers computed
/// in the editor alone, and a ruler that recomputed them would be a ruler whose
/// zero drifts off the page's own margin the moment either side is touched.
///
/// Pure, so the geometry can be reasoned about without a widget: available
/// width in, page and column out.
library;

/// The page's own margins at full width — Word's inch, and the most the page
/// gives up.
const _fullInset = 72.0;

/// The narrowest a margin may get before the text column starts losing more
/// than the margin does.
const _minInset = 16.0;

/// What share of the page a margin may take when the page is too narrow for the
/// full inch. Two of them leave 82% of a squeezed page for the words.
const _insetShare = 0.09;

/// The air above the first paragraph, and below the last.
///
/// The page's top and bottom margins as this editor draws them. Not read from
/// the file: those live in the section's `w:sectPr`, which nothing here writes,
/// so claiming the document's own figure would be claiming a number the editor
/// does not honour. Shared with the vertical ruler for exactly that reason — a
/// ruler that marked an inch where the text starts at 56px would be measuring a
/// page nobody is looking at.
const officePageTopInset = 56.0;
const officePageBottomInset = 72.0;

class OfficePageMetrics {
  const OfficePageMetrics({
    required this.page,
    required this.inset,
    required this.column,
  });

  /// How wide the sheet is drawn, in logical pixels.
  final double page;

  /// The margin either side of the text, inside the sheet.
  final double inset;

  /// What is left for the words — and what a table has to fit inside.
  final double column;

  /// The geometry of a [paperWidthPx] page drawn in [available] pixels.
  ///
  /// Never wider than the pane: a fixed page is what overflowed every table the
  /// moment the window came off full screen. And margins shrink with the page
  /// rather than holding their inch — at the app's narrowest window two 72px
  /// margins are wider than the paper between them, and the text would be laid
  /// out in nothing.
  factory OfficePageMetrics.of(double available, double paperWidthPx) {
    final page = available < paperWidthPx ? available : paperWidthPx;
    final inset = (page * _insetShare).clamp(_minInset, _fullInset);
    return OfficePageMetrics(
      page: page,
      inset: inset,
      column: page - inset * 2,
    );
  }
}
