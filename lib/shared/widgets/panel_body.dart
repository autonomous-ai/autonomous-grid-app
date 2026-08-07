import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
class PanelBody extends StatelessWidget {
  const PanelBody({
    super.key,
    required this.toolbar,
    required this.main,
    this.side,
  });

  /// Region 2 — the row under the tabs. Every feature has one: a breadcrumb, a
  /// working directory, an address.
  final Widget toolbar;

  /// Region 3 — the feature itself.
  final Widget main;

  /// Region 4 — the column on the right, for the features that want one (a file
  /// tree, a list of changed files). Left out entirely by the rest.
  final Widget? side;

  /// The toolbar's height, fixed across features so the seam under it doesn't
  /// move when you switch tabs.
  static const double toolbarHeight = 36;

  @override
  Widget build(BuildContext context) {
    final side = this.side;
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
                    // it at the narrow end and look lost at the wide one.
                    final width = (constraints.maxWidth * 0.3)
                        .clamp(180.0, 280.0)
                        .toDouble();
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: main),
                        const VerticalDivider(width: 1),
                        SizedBox(width: width, child: side),
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
