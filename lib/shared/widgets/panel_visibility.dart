import 'package:flutter/material.dart';

/// Whether the panel tab a surface sits in is the one on screen.
///
/// Open tabs all stay in the tree so switching between them keeps each one's
/// scroll, its open folders and its half-typed boxes. Most of what that implies
/// is handled for free — a hidden tab isn't painted and isn't hit-tested — but
/// two things escape it and have to be told:
///
///  - **Anything in the overlay.** A popover opened from a tab is mounted in the
///    app's overlay, above everything; switching tabs would leave it floating
///    over a surface it has nothing to do with. Whoever opens one closes it
///    when this turns false.
///  - **Work that shouldn't run unwatched.** A tab nobody is looking at has no
///    reason to poll or animate.
///
/// True when nothing says otherwise, so a surface used outside the panel — a
/// test, a dialog — behaves as though it were on screen.
class PanelTabVisible extends InheritedWidget {
  const PanelTabVisible({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PanelTabVisible>()?.visible ??
      true;

  @override
  bool updateShouldNotify(PanelTabVisible oldWidget) =>
      oldWidget.visible != visible;
}
