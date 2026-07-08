import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A frosted "liquid glass" surface — the app's core translucent primitive.
///
/// It layers the three things that make Apple's glass read as *glass*: a heavy
/// backdrop blur, a top-lit frost gradient, and a specular highlight (a crisp
/// lens edge + soft sheen) along the top. Floating panels add a drop shadow so
/// they lift off [AmbientBackground]. The top bar, sidebar, and content panel
/// all wrap their content in this so the whole app shares one glass recipe.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blur = AppGlass.blur,
    this.padding,
    this.border,
    this.fill,
    this.boxShadow,
    this.blurred = true,
    this.sheen = true,
    this.expand = false,
    this.width,
  });

  final Widget child;

  /// Corner rounding for the clip, rim, and shadow. Use [BorderRadius.zero] for
  /// full-bleed chrome (the top bar) that only needs an edge on one side.
  final BorderRadius borderRadius;

  final double blur;
  final EdgeInsetsGeometry? padding;

  /// Overrides the default all-sides rim — pass a one-sided [Border] (e.g.
  /// `Border(bottom: ...)`) for chrome that separates with a single hairline.
  final Border? border;

  /// Overrides the frosted white body — the content panel passes a nearly
  /// opaque dark gradient so dense UI stays readable.
  final Gradient? fill;

  /// Soft shadow for floating panels; omit for full-bleed chrome.
  final List<BoxShadow>? boxShadow;

  /// Skip the backdrop blur when the [fill] is opaque enough that blurring the
  /// backdrop would be wasted work.
  final bool blurred;

  /// The specular top highlight. On for real glass, off is rarely needed.
  final bool sheen;

  /// Stretch to fill the height/width the parent gives, so a child with an
  /// [Expanded] (e.g. a card whose log fills the remaining space) lays out
  /// against a tight box instead of an unbounded one. Off = shrink-wrap the
  /// child, the default for content that sizes itself.
  final bool expand;

  /// Fixed width for the surface — pass `double.infinity` for a card that should
  /// fill its parent's width (e.g. a full-bleed note). Null shrink-wraps to the
  /// child, the default.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final effectiveBorder = border ?? Border.all(color: AppGlass.border);
    final effectiveFill =
        fill ??
        const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppGlass.fillTop, AppGlass.fillBottom],
        );
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    final body = Stack(
      fit: expand ? StackFit.expand : StackFit.loose,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              // A rounded rim needs a uniform border; a one-sided rim must drop
              // the radius or BoxDecoration asserts.
              borderRadius: effectiveBorder.isUniform ? borderRadius : null,
              gradient: effectiveFill,
              border: effectiveBorder,
            ),
          ),
        ),
        if (sheen)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: _Specular()),
          ),
        content,
      ],
    );

    Widget surface = ClipRRect(
      borderRadius: borderRadius,
      child: blurred
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: body,
            )
          : body,
    );

    if (boxShadow != null) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: boxShadow,
        ),
        child: surface,
      );
    }
    if (width != null) {
      surface = SizedBox(width: width, child: surface);
    }
    return surface;
  }
}

/// The specular highlight painted along a glass surface's top edge: a crisp
/// bright hairline that fades out toward the corners, then a soft glow melting
/// downward — the light-catching lens edge that sells the glass.
class _Specular extends StatelessWidget {
  const _Specular();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 1.2,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Colors.transparent, AppGlass.edge, Colors.transparent],
            ),
          ),
        ),
        Container(
          height: 56,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppGlass.sheen, Colors.transparent],
            ),
          ),
        ),
      ],
    );
  }
}
