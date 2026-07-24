import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/meta_label.dart';
import 'onboarding_backdrop.dart';

/// The page every screen *before* the app wears: sign in, first-run setup, and
/// the choose-a-model fork.
///
/// One frame, because those three are one journey. They used to be three
/// designs — a card floating on an aurora, a left-aligned checklist on plain
/// white, and a page of rows — which is three products in the first two minutes,
/// at exactly the moment a new user is deciding whether to trust this thing.
///
/// The shape: an ambient wash across the whole window, and everything the screen
/// has to say on one white card floating at its centre. The card is what the eye
/// lands on; the wash is only there so the app doesn't open onto a blank sheet.
///
/// Centres when the window is tall enough and scrolls when it isn't — these
/// windows get resized small, and a screen the user can't scroll is one they
/// can't finish.
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.meta,
    this.corner,
    this.leading,
  });

  /// A mark above the title, inside the card — the brand, on the one screen
  /// that is the front door. The other two are already inside the product and
  /// don't need reintroducing.
  final Widget? leading;

  final String title;

  /// The one line under the title. Says what this screen wants, or what is
  /// happening — never both.
  final String subtitle;

  /// A counter on the subtitle's line, right-aligned — "1 of 2 steps". Rendered
  /// as a [MetaLabel] so it reads the same as a choice row's badge.
  final String? meta;

  /// Floating in the window's top-right, clear of the macOS traffic lights —
  /// the theme switch on sign-in. Outside the card on purpose: it belongs to the
  /// window, not to what the screen is asking.
  final Widget? corner;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: OnboardingBackdrop()),
          ),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child: _Card(
                      leading: leading,
                      title: title,
                      subtitle: subtitle,
                      meta: meta,
                      children: children,
                    ),
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

/// The white card everything sits on: title, one line under it, then the screen.
///
/// Text stays left-aligned inside it. A centred paragraph is harder to read and
/// leaves the rows below it looking unrelated to the words above — the card
/// already does the work of saying "this, here, is the screen".
class _Card extends StatelessWidget {
  const _Card({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.children,
  });

  final Widget? leading;
  final String title;
  final String subtitle;
  final String? meta;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppCard.base,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppGlass.hair),
          boxShadow: AppCard.heroShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 30, 32, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (leading != null) ...[
                Align(alignment: Alignment.centerLeft, child: leading!),
                const SizedBox(height: 18),
              ],
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
              const SizedBox(height: 22),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
