import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import 'panel_side_layout.dart';
import 'panel_splitter.dart';

/// The inside of one preview-panel tab: a toolbar, the work itself, and an
/// optional column beside it.
///
/// The tab strip above is shared and fixed; everything below it belongs to
/// whichever feature is open. This widget owns only the geometry, so five
/// features can't drift into five different toolbar heights — a tab switch that
/// moves the toolbar a few pixels reads as the whole panel flinching.
///
/// Features live in their own folders (`features/review/presentation`, and so
/// on) and each returns one of these.
class PanelBody extends ConsumerWidget {
  const PanelBody({
    super.key,
    required this.toolbar,
    required this.main,
    this.side,
    this.sideOpen = true,
  });

  /// Region 2 — the row under the tabs. Every feature has one: a breadcrumb, a
  /// working directory, an address.
  final Widget toolbar;

  /// Region 3 — the feature itself.
  final Widget main;

  /// Region 4 — the column on the right, for the features that want one (a file
  /// tree, a list of changed files). Left out entirely by the rest.
  final Widget? side;

  /// Whether that column is out. False slides it away and gives the work its
  /// width; the column stays built behind the clip, which is what lets it come
  /// back with its scroll position and its open folders intact.
  ///
  /// A feature that never hides its column leaves this alone.
  final bool sideOpen;

  /// The toolbar's height, fixed across features so the seam under it doesn't
  /// move when you switch tabs.
  static const double toolbarHeight = 36;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final side = this.side;
    // Null until the user drags the seam; the resolver falls back to a share of
    // the panel, which keeps answering to its width.
    final dragged = ref.watch(panelSideWidthProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: toolbarHeight, child: toolbar),
        const Divider(height: 1),
        Expanded(
          child: side == null
              ? main
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // A share rather than a fixed width: the panel itself is a
                    // share of the window, so a fixed column would eat most of
                    // it at the narrow end and look lost at the wide one — until
                    // the user says otherwise by moving the seam.
                    final width = resolvePanelSideWidth(
                      panelWidth: constraints.maxWidth,
                      override: dragged,
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: main),
                        // The slot narrows to nothing while the column stays
                        // laid out at its full width, pinned to the slot's
                        // leading edge — so the column travels out to the right
                        // with the edge instead of being wiped away in place.
                        // Same recipe as the preview panel's own slide, for the
                        // same reason: animating the column's real width would
                        // squash its rows flat on the way.
                        ClipRect(
                          child: AnimatedContainer(
                            duration: AppMotion.swap,
                            curve: AppMotion.curve,
                            width: sideOpen ? width : 0,
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: width,
                              maxWidth: width,
                              // The seam rides *inside* the column it sizes, the
                              // way the chat pane's does, so the width resolved
                              // here is the whole slot and the work beside it
                              // keeps exactly the rest.
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // The column is on the right, so dragging the
                                  // seam left — a negative delta — widens it.
                                  // Each report resizes from the width just
                                  // resolved, which is what makes the clamps
                                  // hold: a drag past a limit stops there
                                  // instead of banking distance to be paid back
                                  // on the way out.
                                  PanelSplitter(
                                    axis: Axis.vertical,
                                    onDrag: (dx) => ref
                                        .read(panelSideWidthProvider.notifier)
                                        .set(width - dx),
                                    onReset: ref
                                        .read(panelSideWidthProvider.notifier)
                                        .reset,
                                  ),
                                  Expanded(child: side),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A region of the panel that hasn't been built yet.
///
/// Says which region of which feature, because five features showing the same
/// "Coming soon" would leave you unable to tell whether the tab switched.
class PanelTodo extends StatelessWidget {
  const PanelTodo(this.label, {super.key, this.dense = false});

  final String label;

  /// Set inside a toolbar: left-aligned and small, rather than centred in the
  /// space it has.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final text = Text(
      'TODO — $label',
      style: TextStyle(
        fontSize: dense ? 12.5 : 13.5,
        fontWeight: AppFont.medium,
        color: AppPalette.textSecondary,
      ),
    );
    if (!dense) return Center(child: text);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: text,
      ),
    );
  }
}
