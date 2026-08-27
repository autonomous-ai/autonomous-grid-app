import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/theme_mode_labels.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../network/presentation/grid_overview_widgets.dart';
import 'chat_surface_section.dart';
import 'detail_mode_section.dart';
import 'theme_preview_tile.dart';
import 'typography_section.dart';

/// The Appearance settings screen: how the app looks.
///
/// You pick a theme by *seeing* it — three previews of the app wearing each one,
/// the way macOS System Settings does it — rather than by reading three words.
/// This is the one place the choice is made: the account menu used to carry a
/// segmented copy of it, which put a settings control in a menu and said the
/// same thing twice.
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
          'Choose how Grid looks on this Mac — theme, type, how a chat is '
          'drawn, and how much of the assistant’s working-out you want to '
          'see. System follows your macOS setting.',
      // A SingleChildScrollView over a Column, never a ListView: the type
      // settings pushed this past a screenful, but a lazy list keeps the
      // children it has already built across a rebuild — which is one of the two
      // ways a widget gets stranded on the old palette (the other being a
      // `const` boundary). Everything here is built eagerly and rebuilt whole.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Both headings on this screen are SectionHeading, and they have to
            // be: "Theme" and "Typography" are peers, so setting one at 13pt
            // and the other at 19 would rank them.
            //
            // No subtitle here, unlike Typography's. Three labelled pictures of
            // the app wearing each theme explain themselves, and the page's own
            // subtitle already says System follows macOS — a third sentence
            // saying "the palette the app wears" costs a line at the very top
            // of a page that has to scroll, and buys nothing.
            const SectionHeading(title: 'Theme', subtitle: ''),
            const SizedBox(height: 12),
            // Wrap, not Row: the tiles are a fixed size, so a narrow settings
            // pane (or the compact nav rail) reflows them instead of
            // overflowing.
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
            // Space, not a rule: rule 1 of the design system is that depth and
            // separation come from fill and shadow, and the typography block
            // below is already a stack of raised rows. A divider between two
            // sections that are each visibly grouped just adds a line.
            const SizedBox(height: 26),
            const TypographySection(),
            const SizedBox(height: 26),
            // Shape before detail: which surface a chat is drawn in comes
            // first, and the working-out setting below only has anything to
            // show on the message list.
            const ChatSurfaceSection(),
            const SizedBox(height: 26),
            const DetailModeSection(),
          ],
        ),
      ),
    );
  }
}
