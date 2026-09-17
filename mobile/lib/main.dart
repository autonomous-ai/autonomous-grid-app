/// Grid on a phone.
///
/// A remote control, deliberately: it runs no engines, drives no CLI and holds
/// no grid credentials. Everything it shows, it asked the computer for over an
/// end-to-end encrypted channel that the relay in the middle cannot read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import 'logic/appearance_prefs.dart';
import 'presentation/link_screen.dart';

void main() => runApp(const ProviderScope(child: GridMobileApp()));

/// The app.
///
/// Themed from `grid_theme` — the same package the desktop resolves against —
/// rather than from a seeded Material scheme. A seed generates a palette that
/// is internally consistent and nothing to do with Grid: it was why this app
/// looked like a different product from the one it is a remote control for.
///
/// Follows the phone's own light/dark setting until somebody picks otherwise in
/// Settings — the same three-way choice the Mac offers, because a person who set
/// Grid to dark on one of their devices did not mean "only that one".
class GridMobileApp extends ConsumerWidget {
  const GridMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);

    // Ordering matters, and is why this is a statement rather than something
    // tucked into the tree: `buildAppTheme` below reads AppFont.sans and the
    // scaled control metrics, so the settings have to be on AppFont *before*
    // the theme is built, in this same frame. Pushed through the notifier (not
    // AppFont.apply directly) so widgets past a `const` boundary — which a
    // top-down rebuild never reaches — are marked dirty too.
    AppTheme.fonts.apply(
      uiFamily: look.uiFamily,
      codeFamily: look.codeFamily,
      uiScale: look.uiScale,
      codeSize: look.codeSize,
    );

    return MaterialApp(
      title: 'Grid',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: look.themeMode,
      // The app's text size reaches every `Text` as a scale rather than as an
      // edit to every call site.
      //
      // **Multiplied onto the phone's own scale, not substituted for it.** The
      // Mac forces the factor because macOS has no text scaling to respect; a
      // phone does, it is an accessibility setting, and an app that overwrote it
      // would be unreadable for the person who set it (§11). So someone running
      // iOS at 130% who picks "Large" here gets both.
      //
      // `scale(1)` is how a TextScaler reports its factor — exact for the linear
      // scaler iOS reports, and the closest honest reading of a non-linear one.
      //
      // It is also where [_BrightnessSync] goes, rather than around `home`.
      // `builder` wraps the Navigator; `home` is one route *inside* it — so a
      // scope mounted there is not an ancestor of any pushed screen, and every
      // chat, grid and sheet opened on top would be deaf to the palette and the
      // type settings it is supposed to follow. It is still below MaterialApp,
      // which is what lets it read the brightness Material actually resolved.
      builder: (context, child) {
        final data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(
            textScaler: TextScaler.linear(
              data.textScaler.scale(1) * look.uiScale,
            ),
          ),
          child: _BrightnessSync(child: child ?? const SizedBox.shrink()),
        );
      },
      home: const LinkScreen(),
    );
  }
}

/// Keeps [AppTheme.brightness] — the value every colour token resolves against —
/// in step with the theme Material rendered.
///
/// Set synchronously during build, before the child paints, so a token read this
/// frame already sees the right brightness rather than flashing the wrong
/// palette for one frame. [BrightnessScope] then marks every widget that called
/// [AppTheme.watch] dirty, reaching past `const` boundaries a top-down rebuild
/// cannot.
class _BrightnessSync extends StatelessWidget {
  const _BrightnessSync({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.brightness.value = Theme.of(context).brightness;
    return BrightnessScope(child: child);
  }
}
