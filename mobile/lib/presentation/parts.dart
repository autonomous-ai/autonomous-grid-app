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

/// The small, quiet label that names a group of rows, with an optional line
/// explaining what the group is.
///
/// The explanation is what lets a section keep the word the desktop uses for the
/// same thing — "Nodes" is the app's word for a machine on a grid, and a phone
/// that renamed it would leave two screens describing one thing twice.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {this.subtitle = '', this.trailing, super.key});

  /// What the group is called.
  final String text;

  /// One line saying what it is, or empty when the name is enough.
  final String subtitle;

  /// An action belonging to the group, drawn at its right.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppPalette.textFaint,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          // Omitted rather than drawn empty: an empty Text still takes its line
          // box, so a section with nothing to add would push its rows down by a
          // line it never used.
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The one floating action button this app has: the way to start the thing the
/// screen under it lists.
///
/// The app's card rounding rather than a circle, because nothing else here is a
/// stadium and a floating circle reads as another product's button.
class GridFab extends StatelessWidget {
  const GridFab({required this.tooltip, required this.onPressed, super.key});

  /// What it starts.
  final String tooltip;

  /// Starting it.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return FloatingActionButton(
      tooltip: tooltip,
      backgroundColor: AppPalette.accent,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppCard.radius),
      ),
      onPressed: onPressed,
      child: const Icon(Icons.add_rounded, size: 20),
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
  const RowDetail(this.parts, {this.maxLines = 1, super.key});

  /// The pieces, joined with the separator this app uses everywhere. Empty
  /// pieces are dropped rather than leaving a stray dot.
  final List<String> parts;

  /// How many lines it may take. One for a chat's model and when, two for a
  /// machine's specs — six facts about a laptop do not fit a phone's width, and
  /// the first three are not the useful ones.
  final int maxLines;

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
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
