import 'package:flutter/material.dart';

import 'extension_list.dart';
import 'extension_tile_surface.dart';

/// The card-grid counterpart to [ExtensionList]: the same chaptered
/// [ExtensionSection] model, laid out as a wall of cards instead of a column of
/// rows.
///
/// A separate widget rather than a mode on [ExtensionList], because the two
/// answer different questions. A **row** is for a list you scan down one column
/// — a name, a state, a control — and a description would make it a wall of
/// text. A **card** is for a list you browse, where the description is the whole
/// point: it says what you get if you connect this, which is the question
/// somebody looking at thirty unfamiliar service names actually has.
///
/// [ExtensionList] keeps its four callers (skills, plugins, models, engines)
/// untouched. `sectionExtensionItems` and `ExtensionSectionHeader` are shared,
/// so the two layouts chapter and label identically.
class ExtensionGrid<T> extends StatefulWidget {
  const ExtensionGrid({
    super.key,
    required this.sections,
    required this.cardBuilder,
    this.targetCardWidth = 320,
    this.maxColumns = 3,
    this.cardHeight = 118,
  });

  final List<ExtensionSection<T>> sections;
  final Widget Function(BuildContext context, T item) cardBuilder;

  /// The width a card wants. Columns are whatever fits, so a narrow settings
  /// pane collapses to one and a wide window fills out — the layout is decided
  /// by the space, never by a breakpoint list to keep in sync with the window
  /// sizes the app actually gets used at.
  final double targetCardWidth;

  /// The ceiling on columns. Past three the cards stop reading as a grid and
  /// start reading as a table, and a description gets too narrow to be a
  /// sentence.
  final int maxColumns;

  /// Every card is the same height, which is what makes the wall read as a grid
  /// rather than a ragged pile. The cost is that a card must clamp its own text
  /// — see the `maxLines` on each — and the benefit is that nothing reflows when
  /// one service has a longer blurb than its neighbour.
  final double cardHeight;

  @override
  State<ExtensionGrid<T>> createState() => _ExtensionGridState<T>();
}

class _ExtensionGridState<T> extends State<ExtensionGrid<T>> {
  /// Shared with the [Scrollbar] above it, for the reason [ExtensionList]
  /// documents: two controllers on one position asserts.
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - extensionScrollGutter;
        final columns = (available / widget.targetCardWidth).floor().clamp(
          1,
          widget.maxColumns,
        );
        // Grows with the user's text size, but slower than the text does: the
        // card's fixed parts (the mark, the padding) don't scale, so matching
        // the scaler outright leaves a band of empty card at 2×.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final extent = widget.cardHeight * (1 + (scale - 1) * 0.8);

        return Scrollbar(
          controller: _controller,
          child: CustomScrollView(
            controller: _controller,
            slivers: [
              for (final (index, section) in widget.sections.indexed) ...[
                if (section.label.isNotEmpty)
                  SliverPadding(
                    // 18px of air before a header so a new block reads as a
                    // break — the same rhythm `ExtensionList` uses. Not before
                    // the first one, which would push the whole grid down for
                    // nothing.
                    padding: EdgeInsets.only(
                      top: index == 0 ? 0 : 18,
                      bottom: 6,
                      right: extensionScrollGutter,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: ExtensionSectionHeader(
                        label: section.label,
                        count: section.items.length,
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.only(right: extensionScrollGutter),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      mainAxisExtent: extent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) =>
                          widget.cardBuilder(context, section.items[i]),
                      childCount: section.items.length,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
