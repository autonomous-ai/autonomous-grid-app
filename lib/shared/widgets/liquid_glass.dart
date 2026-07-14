import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A reusable Codex-like glass surface for app chrome.
///
/// The treatment is deliberately quiet: a translucent fill, a one-pixel rim, and
/// a soft shadow. Pass a [blurSigma] to turn on a real backdrop blur so whatever
/// sits behind the surface is frosted through it — the glassmorphism the design
/// calls for on the sidebar and floating chrome. With [blurSigma] null it stays a
/// cheap opaque-ish fill (no filter), which is right for surfaces that have
/// nothing meaningful behind them.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.fill,
    this.showShadow = true,
    this.showBorder = false,
    this.borderColor,
    this.borderWidth = 1,
    this.shadow,
    this.blurSigma,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  /// The surface fill; defaults to [AppGlass.surfaceFill] (theme-aware) when null.
  /// Should carry some transparency when [blurSigma] is set so the blur shows.
  final Color? fill;
  final bool showShadow;
  final bool showBorder;

  /// The rim color when [showBorder] is on; defaults to [AppGlass.hair].
  final Color? borderColor;

  /// The rim thickness when [showBorder] is on. 1 is the hairline default; 1.5
  /// gives a surface like the composer a rim that stays visible on pure white.
  final double borderWidth;
  final List<BoxShadow>? shadow;

  /// Backdrop-blur radius. Null = no real blur (just the fill). ~14–18 reads as
  /// frosted glass without smearing text behind it into mush.
  final double? blurSigma;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(20);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(color: fill ?? AppGlass.surfaceFill),
      child: content,
    );

    if (blurSigma != null) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma!, sigmaY: blurSigma!),
        child: surface,
      );
    }

    // Shadow AND border live on the outer box, outside the clip, so the full
    // 1px stroke renders crisply — a border drawn inside the ClipRRect loses its
    // outer half to the clip and reads as a faint half-pixel line.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: showBorder
            ? Border.all(
                color: borderColor ?? AppGlass.hair,
                width: borderWidth,
              )
            : null,
        boxShadow: showShadow ? (shadow ?? AppGlass.shadow) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: surface,
      ),
    );
  }
}
