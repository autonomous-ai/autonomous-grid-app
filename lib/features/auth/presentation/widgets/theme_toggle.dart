import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/theme/theme_mode_labels.dart';

/// A compact Light / Dark / System switch for the sign-in screen's corner. Reads
/// and writes the same persisted [themeModeProvider] / [chatPrefsProvider] the
/// Appearance settings screen does — so the choice is available before the user
/// signs in, and survives a restart. Rendered as three quiet icon buttons in a
/// pill, to sit lightly in the corner.
class ThemeToggle extends ConsumerWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final current = ref.watch(themeModeProvider);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppGlass.hair),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ThemeMode.values)
              _ThemeToggleButton(
                icon: _loginThemeIcon(mode),
                tooltip: themeModeLabel(mode),
                selected: mode == current,
                onTap: () =>
                    ref.read(chatPrefsProvider.notifier).setThemeMode(mode),
              ),
          ],
        ),
      ),
    );
  }
}

/// The glyph for a theme choice *on the sign-in screen*. Diverges from the
/// shared [themeModeIcon] only for [ThemeMode.system]: a split light/dark disc
/// reads as "follow the OS" far more clearly than the shared auto-badge, which
/// renders close to a settings cog at this small size. Light/Dark keep the
/// sun/moon.
IconData _loginThemeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.system => Icons.brightness_6_outlined,
  _ => themeModeIcon(mode),
};

/// One icon cell of [ThemeToggle] — filled when it's the active mode, otherwise
/// a quiet tappable glyph.
class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? AppPalette.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: foreground),
          ),
        ),
      ),
    );
  }
}
