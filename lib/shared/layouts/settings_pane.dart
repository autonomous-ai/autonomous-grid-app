import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';
import 'shell_state.dart';
import 'widgets/section_view.dart';
import 'widgets/sidebar_item.dart';

/// Everything you set up once, behind one door: the grids you can talk to, what
/// this computer runs, Telegram, and how to point other apps at it.
///
/// It takes the whole window — none of this is daily work, so it doesn't belong
/// in the rail you chat from — and keeps the shape of the grid list it grew out
/// of: pick on the left, work on the right.
class SettingsPane extends ConsumerWidget {
  const SettingsPane({super.key, required this.section});

  /// The settings screen to show — one of [kSettingsSections].
  final ShellSection section;

  /// Under this, a labelled nav column would squeeze the screen it exists to
  /// show (Grids brings its own list), so it drops to icons instead.
  static const double _compactBelow = 1000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SettingsHeader(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsNav(
                  section: section,
                  compact: constraints.maxWidth < _compactBelow,
                  onSelect: (target) =>
                      ref.read(shellSectionProvider.notifier).select(target),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: SectionView(section: section)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The way back, and the window's drag handle — Settings replaces the app frame,
/// so the top bar's title and traffic-light inset have to come from here.
class _SettingsHeader extends ConsumerWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final left = Platform.isMacOS ? 78.0 : 16.0;
    return DragToMoveArea(
      child: SizedBox(
        height: 54,
        child: DecoratedBox(
          decoration: BoxDecoration(color: AppPalette.windowBg),
          child: Padding(
            padding: EdgeInsets.fromLTRB(left, 10, 18, 8),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppGlass.surfaceFill,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: AppGlass.cardShadow,
                  ),
                  child: TextButton.icon(
                    onPressed: () {
                      final notifier = ref.read(shellSectionProvider.notifier);
                      // Return to wherever the user was before Settings, not
                      // always Chat — they might have been mid-task in Grids.
                      notifier.select(notifier.previous);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppPalette.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 34),
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(Icons.arrow_back_rounded, size: 17),
                    label: const Text('Back to app'),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Settings',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The settings list: one row per screen, the open one highlighted.
class _SettingsNav extends StatelessWidget {
  const _SettingsNav({
    required this.section,
    required this.compact,
    required this.onSelect,
  });

  final ShellSection section;
  final bool compact;
  final ValueChanged<ShellSection> onSelect;

  static const double width = 224;
  static const double compactWidth = 60;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? compactWidth : width,
      color: AppSurface.recess,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            for (final target in kSettingsSections)
              if (compact)
                _NavIcon(
                  target: target,
                  selected: target == section,
                  onTap: () => onSelect(target),
                )
              else
                SidebarItem(
                  icon: target.icon,
                  label: target.label,
                  selected: target == section,
                  onTap: () => onSelect(target),
                ),
          ],
        ),
      ),
    );
  }
}

/// The same row with the label dropped, for a window too narrow to hold both the
/// label column and the screen it opens. The name lives in the tooltip.
class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final ShellSection target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IconButton(
        tooltip: target.label,
        onPressed: onTap,
        icon: Icon(target.icon, size: 18),
        style: IconButton.styleFrom(
          foregroundColor: selected
              ? AppPalette.textPrimary
              : AppPalette.textSecondary,
          backgroundColor: selected
              ? AppSurface.selectedFill
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
