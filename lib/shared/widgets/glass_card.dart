import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// How a [GlassCard] is dressed.
enum GlassCardStyle {
  /// A standard content card: white, a hairline rim, a soft lift.
  card,

  /// The focal card on a screen (e.g. the running engine): an accent wash and
  /// rim so it leads the surfaces below it.
  hero,

  /// A recessed inner surface — a tinted fill with a hairline rim, no wash/glow.
  /// For list tiles and inner boxes (a live banner, a log panel) nested inside a
  /// [card]/[hero], so they read as set *into* it.
  inset,
}

/// A content card: a white surface with a hairline rim and a soft lift, dressed
/// with an accent wash when it leads the screen (the [AppCard] recipe).
///
/// Cards carry the dense content — a grid's details, an engine's state — so they
/// stay quiet and let the text do the work; only the focal card on a screen wears
/// the accent.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.style = GlassCardStyle.card,
    this.padding,
    this.borderRadius,
    this.expand = false,
    this.width,
  });

  final Widget child;
  final GlassCardStyle style;
  final EdgeInsetsGeometry? padding;

  /// Corner rounding; defaults to [AppCard.radius] (or [AppCard.insetRadius] for
  /// [GlassCardStyle.inset]).
  final BorderRadius? borderRadius;

  /// Stretch to fill the height/width the parent gives — for a card whose child
  /// has an [Expanded] (e.g. the engine card whose log fills the space). Off
  /// shrink-wraps the child, the default.
  final bool expand;

  /// Fixed width; pass `double.infinity` for a full-bleed card (e.g. a note).
  final double? width;

  bool get _isInset => style == GlassCardStyle.inset;

  @override
  Widget build(BuildContext context) {
    // const-constructed and reads AppCard tokens — without this it never
    // rebuilds on a theme flip and keeps the palette it was first built with.
    // See AppTheme.watch.
    AppTheme.watch(context);
    final radius =
        borderRadius ??
        BorderRadius.circular(_isInset ? AppCard.insetRadius : AppCard.radius);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    final layers = <Widget>[
      // Base surface + rim.
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _isInset ? AppCard.inset : AppCard.base,
            borderRadius: radius,
          ),
        ),
      ),
      // Indigo accent wash — a diagonal tint that fades out toward the far
      // corner. Skipped on an inset surface, which stays a calm recess.
      if (!_isInset)
        Positioned.fill(child: DecoratedBox(decoration: _washDecoration())),
      // Soft accent aura anchored to the top-right corner (card/hero only).
      if (!_isInset) const Positioned(top: -120, right: -120, child: _Aura()),
      // Crisp specular hairline just inside the top edge (card/hero only).
      if (!_isInset)
        const Positioned(top: 0, left: 16, right: 16, child: _TopHairline()),
      content,
    ];

    Widget surface = ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: expand ? StackFit.expand : StackFit.loose,
        children: layers,
      ),
    );

    if (!_isInset) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: style == GlassCardStyle.hero
              ? AppCard.heroShadow
              : AppCard.shadow,
        ),
        child: surface,
      );
    }

    if (width != null) surface = SizedBox(width: width, child: surface);
    return surface;
  }

  BoxDecoration _washDecoration() => BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: style == GlassCardStyle.hero
          ? [AppCard.tint18, AppCard.tint10, Colors.transparent]
          : [AppCard.tint10, Colors.transparent],
      stops: style == GlassCardStyle.hero
          ? const [0.0, 0.3, 0.66]
          : const [0.0, 0.6],
    ),
  );
}

/// A faint indigo radial glow that adds depth to a card's top-right corner
/// without a hard edge — small and low-opacity so it never reads as a stray blob.
class _Aura extends StatelessWidget {
  const _Aura();

  @override
  Widget build(BuildContext context) {
    // const child of a const card — it needs its own watch or the aura keeps the
    // first theme's tint. See AppTheme.watch.
    AppTheme.watch(context);
    return IgnorePointer(
      child: SizedBox(
        width: 300,
        height: 300,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              radius: 0.5,
              colors: [AppCard.tint10, Colors.transparent],
              stops: [0.0, 0.85],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bright lens hairline along a card's top edge — the light-catching edge
/// that sells the glass. Fades out toward the corners.
class _TopHairline extends StatelessWidget {
  const _TopHairline();

  @override
  Widget build(BuildContext context) {
    // Same as _Aura: a const child reading a token needs its own watch.
    AppTheme.watch(context);
    return IgnorePointer(
      child: SizedBox(
        height: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                AppCard.highlightEdge,
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
