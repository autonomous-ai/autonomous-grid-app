import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/meta_label.dart';

/// The page every screen *before* the app wears: sign in, first-run setup, and
/// the choose-a-model fork.
///
/// One frame, because those three are one journey. They used to be three
/// designs: a card floating on an animated aurora with an orbiting seal, a
/// left-aligned checklist, and a plain page of rows — three products in the
/// first two minutes, at exactly the moment a new user is deciding whether to
/// trust this thing. The frame is deliberately plain: the window's own
/// background, a left-aligned title and one line under it, and whatever the
/// screen has to say below that.
///
/// Scrolls rather than centring vertically: these windows get resized small, and
/// a screen the user can't scroll is one they can't finish.
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.meta,
    this.corner,
  });

  final String title;

  /// The one line under the title. Says what this screen wants, or what is
  /// happening — never both.
  final String subtitle;

  /// A counter on the subtitle's line, right-aligned — "1 of 2 steps". Rendered
  /// as a [MetaLabel] so it reads the same as a choice row's badge.
  final String? meta;

  /// Floating in the window's top-right, clear of the macOS traffic lights —
  /// the theme switch on sign-in. Outside the content column on purpose: it
  /// belongs to the window, not to what the screen is asking.
  final Widget? corner;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              subtitle,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: AppPalette.textSecondary,
                              ),
                            ),
                          ),
                          if (meta != null) ...[
                            const SizedBox(width: 12),
                            MetaLabel(meta!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 24),
                      ...children,
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (corner != null) Positioned(top: 18, right: 18, child: corner!),
        ],
      ),
    );
  }
}
