import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../theme/app_theme.dart';

/// A segment sits inside the 10-radius track with 3px of padding, so it rounds
/// one step less — a nested box must never be rounder than its parent.
final _segmentRadius = BorderRadius.circular(AppControl.radius);

/// The Light / Dark / System choice, as a compact three-way segmented control
/// for the account menu. Reads and writes the persisted [themeModeProvider], so
/// the pick survives a restart; the whole app re-themes the moment it changes.
///
/// The Appearance settings screen offers the same choice as three preview tiles
/// instead — a menu is too narrow to show a theme, and a settings pane is too
/// wide to justify not showing one. Both drive this one provider, so they can't
/// disagree.
class ThemeModePicker extends ConsumerWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The account menu builds this as `const`, so the parent's own watch does
    // not reach it: without this the whole control — track, labels, the caption
    // — stays on whichever palette it first built in. The theme picker being
    // the one thing in the menu that doesn't follow the theme.
    AppTheme.watch(context);
    final current = ref.watch(themeModeProvider);
    return Padding(
      // 15 to the menu's label column (6 gutter + 9 inner pad), so the caption
      // starts where "Settings" and "Sign out" do. It was 14+4=18 against the
      // rows' old 18, and both were off the row grid.
      padding: const EdgeInsets.fromLTRB(15, 6, 15, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              // A section caption, in the same 10.5/w700/0.6-tracked uppercase
              // the model picker's group headers use — the app's one "this
              // labels the block under it" voice. It was 11.5/w600/0.3 mixed
              // case, which read as a disabled menu row instead.
              'Appearance'.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                // textSecondary, not textFaint: a heading must not be quieter
                // than the thing it heads. Same fix the model picker's group
                // header carries, and it clears 4.5:1 on both panels.
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              // A recessed track, no rim — depth comes from the fill. Measures
              // 1.21:1 against the dark panel and 1.07:1 against light: faint
              // by design, since the selected segment's accent fill is what
              // carries the control, not the well behind it.
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
/// when picked. Kept local to the picker.
///
/// A stack, not a row. macOS lays a segmented control on one line, and this was
/// briefly built that way — but the menu is only ~230px wide once its gutters are
/// taken out, which leaves ~70px a cell. Side by side, the glyph eats enough of
/// that for "System" to ellipsize to "Syst…": a control that can't say the name
/// of its own option. Stacking gives the label the cell's full width, and the
/// one-line rule is worth less than a legible word.
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
    // White on accent measures 5.52:1; textSecondary on the track is 4.98:1
    // dark / 5.80:1 light — both clear 4.5:1, so the label is legible picked or
    // not, and selection isn't carried by colour alone (the fill and the w600
    // say it too).
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : Colors.transparent,
      borderRadius: _segmentRadius,
      child: InkWell(
        borderRadius: _segmentRadius,
        onTap: onTap,
        // An unpicked segment had no hover at all — the one control in the menu
        // that didn't answer the pointer. The picked one stays put: it's
        // already the loudest thing here, and lightening it would read as a
        // second selected state.
        hoverColor: selected ? Colors.transparent : AppSurface.hoverFill,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                // No ellipsis: at this width the label always fits, and if a
                // longer one ever doesn't, a clipped word is the bug — not
                // something to render tidily.
                style: TextStyle(
                  fontFamily: AppFont.sans,
                  fontFamilyFallback: AppFont.sansFallback,
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
