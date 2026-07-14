import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A reusable frosted surface for app chrome.
///
/// It gives controls a liquid-glass treatment without each feature retyping the
/// blur, rim, highlight, and shadow recipe.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.fill = AppGlass.surfaceFill,
    this.showShadow = true,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color fill;
  final bool showShadow;
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
        boxShadow: showShadow ? AppGlass.shadow : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: Border.all(color: AppGlass.hair),
            ),
            child: Stack(
              children: [
                const Positioned.fill(child: _GlassWash()),
                const Positioned(top: 0, left: 14, right: 14, child: _Lens()),
                content,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassWash extends StatelessWidget {
  const _GlassWash();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppGlass.lens,
              AppGlass.wash,
              AppGlass.warmWash,
              Colors.transparent,
            ],
            stops: [0, 0.34, 0.62, 1],
          ),
        ),
      ),
    );
  }
}

class _Lens extends StatelessWidget {
  const _Lens();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: SizedBox(
        height: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, AppGlass.rim, Colors.transparent],
            ),
          ),
        ),
      ),
    );
  }
}
