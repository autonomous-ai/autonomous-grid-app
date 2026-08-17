import 'dart:typed_data';

import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// The Read view: the document with its own formatting — fonts, alignment,
/// spacing, tables, pictures, headers and footers — drawn by
/// `docx_file_viewer`.
///
/// The reading and the drawing are that package's (`docx_creator` underneath it),
/// not ours. That is the point of it: it already covers what a hand-written
/// renderer takes weeks to reach — the styles.xml cascade, numbering, page setup,
/// merged cells, footnotes, print layout — and it is one dependency rather than
/// one more thing this app has to keep correct.
///
/// **Reading the file is all it does.** Saving still goes through
/// `docx_edit.dart`, and has to: this package writes a `.docx` by generating one
/// from its own model, which loses whatever that model doesn't carry (content
/// controls, tracked changes, embedded charts). The editor's promise is that
/// paragraphs you didn't touch come back byte for byte, and only a patch can keep
/// it.
class OfficeFormattedView extends StatelessWidget {
  const OfficeFormattedView({
    super.key,
    required this.bytes,
    required this.pageWidth,
  });

  /// The file, as read off disk.
  final Uint8List bytes;

  /// How wide the document's own pages are, in logical pixels — A4 and Letter
  /// differ, and a document laid out for one reads wrong at the other's measure.
  final double pageWidth;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DocxView(
      bytes: bytes,
      config: DocxViewConfig(
        // The page stays paper in both app themes, and this is where that is
        // enforced for the library's half of the screen: its light preset is a
        // fixed white/near-black pair that reads nothing from `Theme.of` — so a
        // user on Dark gets dark chrome around a white page, which is what Word
        // does and what was asked for.
        theme: DocxViewTheme.light(),
        // The desk *is* app chrome, so it follows the theme — the one colour here
        // that should.
        backgroundColor: AppPalette.paperDesk,
        // One continuous sheet, **not** the package's print layout — and this is
        // not a preference, it is a bug worked around.
        //
        // `DocxPageMode.paged` builds each page as a fixed-height
        // `Clip.hardEdge` container whose inner scroll view is
        // `NeverScrollableScrollPhysics`, and decides what fits by estimating
        // 24px a line and 8px a character. The estimate counts no inline
        // pictures at all, so on a document with images a page overruns its own
        // height and everything past the overrun is clipped away with no way to
        // scroll to it: three pictures in, two of them gone, and pages missing
        // after that. (Read against docx_file_viewer 1.0.3,
        // `docx_widget_generator.dart` `_generatePagedWidgets` /
        // `_buildPageContainer`.)
        //
        // Continuous mode puts the same widgets in a real scroll view with no
        // fixed height and no clip. Page boundaries are lost; the document is
        // not. Showing everything in one column beats drawing page edges in the
        // wrong place and hiding what falls outside them.
        pageMode: DocxPageMode.continuous,
        // The sheet keeps the document's own width, read from its `w:sectPr` —
        // in continuous mode this only sizes the paper, so no pagination rides
        // on it.
        pageWidth: pageWidth,
        showPageBreaks: false,
        // Off, and not because zoom isn't wanted: it wraps the document in an
        // `InteractiveViewer`, which takes the trackpad's two-finger scroll for
        // panning and leaves the page feeling stuck. A zoom control that doesn't
        // fight scrolling is its own piece of work.
        enableZoom: false,
        // The search bar belongs to the package's other widget
        // (`DocxViewWithSearch`) and would arrive as chrome inside our pane, with
        // its own Material text field. The app has ⌘K for finding things.
        enableSearch: false,
        enableSelection: true,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      ),
    );
  }
}
