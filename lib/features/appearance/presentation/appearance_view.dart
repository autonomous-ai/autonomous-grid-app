import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/layouts/widgets/theme_mode_picker.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/section_scaffold.dart';
import 'theme_preview_tile.dart';

/// The Appearance settings screen: how the app looks.
///
/// You pick a theme by *seeing* it — three previews of the app wearing each one,
/// the way macOS System Settings does it — rather than by reading three words.
/// The segmented [ThemeModePicker] still lives in the account menu, where a
/// row of pictures wouldn't fit; both drive the one persisted `themeModeProvider`,
/// so they can't disagree.
class AppearanceView extends ConsumerWidget {
  const AppearanceView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reads AppPalette below, so it has to watch. `ref.watch(themeModeProvider)`
    // is not the same signal: it fires when the *choice* changes, while the
    // tokens resolve against the *brightness* — and under a "System" pick the Mac
    // can flip the palette without the choice moving at all. Without this the
    // "Theme" caption below stayed on whichever palette it first built in
    // (white ink, on white). See AppTheme.watch.
    AppTheme.watch(context);
    final current = ref.watch(themeModeProvider);
    return SectionScaffold(
      title: 'Appearance',
      subtitle:
          'Choose how Grid looks on this Mac. '
          'System follows your macOS setting.',
      // A Column, not a ListView: the content is three tiles and a caption, so
      // there's nothing to scroll — and a lazy list would keep those children
      // across a rebuild, which is one of the two ways a widget gets stranded on
      // the old palette (the other being a `const` boundary).
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Theme',
            style: TextStyle(
              fontFamily: AppFont.sans,
              fontFamilyFallback: AppFont.sansFallback,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          // Wrap, not Row: the tiles are a fixed size, so a narrow settings pane
          // (or the compact nav rail) reflows them instead of overflowing.
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: [
              for (final mode in ThemeMode.values)
                ThemePreviewTile(
                  mode: mode,
                  label: themeModeLabel(mode),
                  selected: mode == current,
                  onTap: () =>
                      ref.read(chatPrefsProvider.notifier).setThemeMode(mode),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
