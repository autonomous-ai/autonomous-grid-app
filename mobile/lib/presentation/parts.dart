/// The handful of surfaces every screen in this app is built from.
///
/// Recipes, not new design: each one is the same combination of tokens the
/// desktop uses for the same job — a card is `AppCard.base` at radius 12 behind
/// a hairline rim and a soft shadow, a row is `AppGlass.rowFill` at the same
/// rounding. Depth comes from **rim + shadow**, never from a heavy border.
///
/// Every widget here calls [AppTheme.watch] at the top of `build`. That is not
/// ceremony: these have `const` constructors, and a `const` child is
/// reference-identical across its parent's rebuild, so without it a card stays
/// on the palette it first built with — a light card left on a dark page when
/// the phone switches appearance.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

/// A content card: the surface a group of related things sits on.
class GridCard extends StatelessWidget {
  const GridCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  /// What it holds.
  final Widget child;

  /// Room inside it.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppCard.hair),
        boxShadow: AppCard.shadow,
      ),
      child: child,
    );
  }
}

/// A row sitting directly on the page, tappable.
///
/// Flat rather than carded: a list of these reads as a list, where a stack of
/// shadowed cards reads as a pile of separate objects.
///
/// Not `GridRow` — that name already belongs to the record describing one grid,
/// and a widget sharing it would make every import a coin toss.
class GridListRow extends StatelessWidget {
  const GridListRow({required this.child, this.onTap, super.key});

  /// What it shows.
  final Widget child;

  /// What opens it, or null when it is not a way in.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppCard.radius);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppGlass.rowFill,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // The card-row padding from the style guide: 14 across, 11 down.
            padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The small, quiet label that names a group of rows.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {this.trailing, super.key});

  /// What the group is called.
  final String text;

  /// An action belonging to the group, drawn at its right.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: AppPalette.textFaint),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A status dot — green when something is live, grey when it is not.
class GridDot extends StatelessWidget {
  const GridDot({required this.live, super.key});

  /// Whether the thing this marks is up.
  final bool live;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: live ? AppPalette.online : AppPalette.offline,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A line of secondary detail under a title — model, project, when.
class RowDetail extends StatelessWidget {
  const RowDetail(this.parts, {super.key});

  /// The pieces, joined with the separator this app uses everywhere. Empty
  /// pieces are dropped rather than leaving a stray dot.
  final List<String> parts;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final text = parts.where((part) => part.isNotEmpty).join(' · ');
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
