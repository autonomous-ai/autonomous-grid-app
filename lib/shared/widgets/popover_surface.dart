import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'labeled_field.dart';

/// What a floating panel is drawn on: the app's menu chrome, so a popover and a
/// menu opened on the same screen are not two kinds of surface.
///
/// Shared rather than owned by the toolbar it started in — the sidebar's chat
/// preview hangs off a row, not a toolbar, and a second copy of this recipe is
/// how two floating surfaces drift apart.
class PopoverSurface extends StatelessWidget {
  const PopoverSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 5),
  });

  final Widget child;

  /// Vertical only by default: menu rows carry their own horizontal gutter so
  /// their highlight reads as an inset pill, and side padding here would double
  /// it. A panel of plain content passes its own inset instead.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      color: appMenuFill(),
      elevation: 12,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppGlass.hair),
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}
