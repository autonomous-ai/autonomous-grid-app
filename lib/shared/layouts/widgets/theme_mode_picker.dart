import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../theme/app_theme.dart';

/// The Light / Dark / System choice, as a compact three-way segmented control for
/// the account menu. Reads and writes the persisted [themeModeProvider], so the
/// pick survives a restart; the whole app re-themes the moment it changes.
class ThemeModePicker extends ConsumerWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeModeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              'Appearance',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: AppPalette.textFaint,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppSurface.recess,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  for (final mode in ThemeMode.values)
                    Expanded(
                      child: _Segment(
                        icon: themeModeIcon(mode),
                        label: themeModeLabel(mode),
                        selected: mode == current,
                        onTap: () => ref
                            .read(chatPrefsProvider.notifier)
                            .setThemeMode(mode),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One cell of the segmented control — an icon over its label, tinted the accent
/// when picked. Kept local to the picker; it's a denser layout than [PillChoice].
class _Segment extends StatelessWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The theme picker of all things must follow the theme: without this the
    // segment you just switched to keeps the old palette until something else
    // rebuilds it.
    AppTheme.watch(context);
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name of a theme choice, as the user reads it.
String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
  ThemeMode.system => 'System',
};

/// The glyph for a theme choice — a sun, a moon, and "follow the machine".
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.light => Icons.light_mode_outlined,
  ThemeMode.dark => Icons.dark_mode_outlined,
  ThemeMode.system => Icons.brightness_auto_outlined,
};
