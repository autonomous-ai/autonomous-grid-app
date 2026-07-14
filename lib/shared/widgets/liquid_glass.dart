import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A reusable Codex-like glass surface for app chrome.
///
/// The treatment is deliberately quiet: a translucent white fill, a one-pixel
/// rim, and a soft shadow. No color wash, so the UI stays close to Codex.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.fill = AppGlass.surfaceFill,
    this.showShadow = true,
    this.showBorder = false,
    this.shadow,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color fill;
  final bool showShadow;
  final bool showBorder;
  final List<BoxShadow>? shadow;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(20);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: showShadow ? (shadow ?? AppGlass.shadow) : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: radius,
            border: showBorder ? Border.all(color: AppGlass.hair) : null,
          ),
          child: content,
        ),
      ),
    );
  }
}
