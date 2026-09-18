/// The bar along the bottom of the app: the four places there are to be.
///
/// A footer rather than one long scroll, which is what this app was. The scroll
/// put chats, projects and grids on top of each other in a fixed order, so
/// finding a project meant reading past five conversations, and the list of
/// grids was below the fold on every phone. Four fixed places are the phone's
/// own convention and they cost one tap each, from anywhere.
///
/// Drawn by hand rather than with `NavigationBar`, because Material's own bar
/// puts a filled pill behind the selected icon — a second, louder surface on a
/// screen whose whole design is one bright thing at a time. Here the accent
/// colour alone says which place you are in.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

/// Where the app can be.
enum HomeTab {
  /// Every conversation on the computer — the thing people open this for.
  chats(Icons.chat_bubble_outline, Icons.chat_bubble, 'Chats'),

  /// The folders that work happens in.
  projects(Icons.folder_outlined, Icons.folder, 'Projects'),

  /// What the computer is signed in to, and how strong each one is.
  grids(Icons.bolt_outlined, Icons.bolt, 'Grids'),

  /// The computer this phone is paired with, and the way to forget it.
  settings(Icons.settings_outlined, Icons.settings, 'Settings');

  const HomeTab(this.icon, this.activeIcon, this.label);

  /// How it looks when you are somewhere else.
  final IconData icon;

  /// How it looks when you are here — the same glyph, filled, so the shape
  /// stays recognisable while the weight changes.
  final IconData activeIcon;

  /// What it is called, in the bar and in the title above it.
  final String label;
}

/// The bar itself.
class HomeFooter extends StatelessWidget {
  const HomeFooter({required this.current, required this.onPick, super.key});

  /// Where the app is now.
  final HomeTab current;

  /// Go somewhere else.
  final ValueChanged<HomeTab> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      // The bar's own height above the home indicator, which SafeArea adds
      // under it — a fixed height here would either clip the labels on a phone
      // with a notch or float the bar off the bottom on one without.
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (final tab in HomeTab.values)
                Expanded(
                  child: _Destination(
                    tab: tab,
                    selected: tab == current,
                    onTap: () => onPick(tab),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One place in the bar.
class _Destination extends StatelessWidget {
  const _Destination({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final HomeTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final color = selected ? AppPalette.accent : AppPalette.textFaint;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        // The whole quarter of the bar is the target, not the glyph: a 20px
        // icon is half of what a thumb needs.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? tab.activeIcon : tab.icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(
              tab.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
