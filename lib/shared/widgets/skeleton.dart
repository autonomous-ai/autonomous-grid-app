import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'pulse.dart';

/// A shape-preserving placeholder for content that hasn't arrived.
///
/// A skeleton beats a spinner whenever you already know the *shape* of what's
/// loading: the layout doesn't jump when the data lands, and the wait reads as
/// "your rows are coming" rather than "something is happening somewhere". Use
/// [LoadingView] only when the shape is genuinely unknown.
///
/// The pulse is an opacity breath rather than the usual shimmer sweep — a bright
/// band strobing across the pane fights the app's minimalist direction, and the
/// breath is quieter at the same job. It holds still under Reduce Motion; see
/// [Pulse].
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
    this.shape = BoxShape.rectangle,
  });

  /// Null stretches to the parent's width.
  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  /// A circular block — an avatar or an icon slot. [size] is the diameter.
  const Skeleton.circle({super.key, required double size})
    : width = size,
      height = size,
      radius = 0,
      shape = BoxShape.circle;

  /// A line of text. [width] is usually a fraction of the row via [SkeletonLine].
  const Skeleton.text({super.key, this.width, this.height = 12})
    : radius = 4,
      shape = BoxShape.rectangle;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The skeleton sits *on* a card, so it borrows the recessed-well token
    // rather than a card fill — it must read as an absence, not a surface.
    final base = AppSurface.recess;
    return Pulse(
      duration: const Duration(milliseconds: 1100),
      builder: (context, t, _) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Color.lerp(base, AppSurface.recessHover, t),
          borderRadius: shape == BoxShape.rectangle
              ? BorderRadius.circular(radius)
              : null,
          shape: shape,
        ),
      ),
    );
  }
}

/// A text line whose width is a fraction of the available row — the trick that
/// stops a block of skeleton lines looking like a solid grey slab.
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({super.key, this.widthFactor = 1, this.height = 12});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Skeleton.text(height: height),
    );
  }
}

/// A stand-in for a list row: an optional leading circle and two stacked lines
/// of unequal width.
///
/// This is the shape most of the app's loading lists want — grids, plugins,
/// skills, members, jobs.
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({
    super.key,
    this.leading = true,
    this.subtitle = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  final bool leading;
  final bool subtitle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading) ...[
            const Skeleton.circle(size: 28),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SkeletonLine(widthFactor: 0.42, height: 12),
                if (subtitle) ...[
                  const SizedBox(height: 7),
                  const SkeletonLine(widthFactor: 0.68, height: 10),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A column of [SkeletonListTile]s — the whole loading state for a list pane.
///
/// The rows fade out down the column so the block reads as "more below",
/// not as a wall that ends abruptly at an arbitrary row.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.rows = 5,
    this.leading = true,
    this.subtitle = true,
  });

  final int rows;
  final bool leading;
  final bool subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Opacity(
            opacity: 1 - (i / rows) * 0.65,
            child: SkeletonListTile(leading: leading, subtitle: subtitle),
          ),
      ],
    );
  }
}
