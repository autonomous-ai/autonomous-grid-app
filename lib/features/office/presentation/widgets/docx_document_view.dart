import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/docx/docx_model.dart';

import 'docx_block_view.dart';

/// The document, on paper, with its own formatting.
///
/// The sheet is the width `w:sectPr` asks for — A4 and Letter are different
/// widths and a document laid out for one looks wrong on the other — with the
/// document's own margins as its padding. What it is *not* is paginated: this is
/// one continuous column of the document's blocks, so a page break lands wherever
/// the text runs out rather than where Word would put it. Matching Word there
/// needs real font line metrics, which is its own piece of work.
///
/// Lazy on purpose ([ListView.builder]): a long document is hundreds of
/// paragraphs, and building all of them to show the first screenful is the
/// difference between opening instantly and hanging on a thesis.
class DocxDocumentView extends StatelessWidget {
  const DocxDocumentView({super.key, required this.doc});

  final ParsedDocx doc;

  @override
  Widget build(BuildContext context) {
    final section = doc.section;
    final markers = doc.markers;
    return Center(
      child: SizedBox(
        width: section.pageWidthPx,
        child: ColoredBox(
          // Paper, in both themes — see the token's own note.
          color: AppPalette.paper,
          // The page's own text baseline, cutting the app's off at the root.
          //
          // Every span the renderer builds names its colour, so this changes
          // nothing today — it is here so that it cannot *start* mattering. A
          // `TextStyle` inherits from the ambient [DefaultTextStyle], which in
          // dark mode is near-white ink: one span added later without a colour
          // would come out white on white, and only in one theme, which is the
          // kind of bug that ships.
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: AppPalette.paperInk),
            child: Scrollbar(
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  section.marginLeftPx,
                  section.marginTopPx,
                  section.marginRightPx,
                  section.marginBottomPx,
                ),
                itemCount: doc.blocks.length,
                itemBuilder: (context, index) => DocxBlockView(
                  doc: doc,
                  block: doc.blocks[index],
                  markers: markers,
                  availableWidth: section.bodyWidthPx,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
