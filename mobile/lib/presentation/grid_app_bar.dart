/// The bar at the top of every screen.
///
/// Built here rather than taken from Material's default because the desktop has
/// no AppBar to inherit a look from: it is a window with a toolbar, so the
/// shared theme never had an opinion about this one. The opinion it *does* have
/// is the one applied — flat surface, a 1px hairline instead of an elevation
/// shadow, and a 17pt semibold title, which is the desktop's `titleMedium`.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

/// Grid's top bar.
class GridAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GridAppBar({required this.title, this.actions = const [], super.key});

  /// What this screen is called.
  final String title;

  /// What can be done to it from here.
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AppBar(
      title: Text(title),
      centerTitle: true,
      toolbarHeight: 52,
      titleTextStyle: Theme.of(context).textTheme.titleMedium,
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      // Depth from a hairline, never a shadow — the whole app's rule.
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: AppPalette.textSecondary, size: 20),
      shape: Border(bottom: BorderSide(color: AppPalette.divider)),
      actions: [...actions, const SizedBox(width: 4)],
    );
  }
}

/// An icon action in the bar, sized for a thumb rather than a pointer.
class GridBarButton extends StatelessWidget {
  const GridBarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  /// The glyph.
  final IconData icon;

  /// What it does, for anyone holding a finger on it.
  final String tooltip;

  /// Doing it.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 20,
      color: AppPalette.textSecondary,
      icon: Icon(icon),
    );
  }
}
