/// Grid on a phone.
///
/// A remote control, deliberately: it runs no engines, drives no CLI and holds
/// no grid credentials. Everything it shows, it asked the computer for over an
/// end-to-end encrypted channel that the relay in the middle cannot read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import 'presentation/link_screen.dart';

void main() => runApp(const ProviderScope(child: GridMobileApp()));

/// The app.
///
/// Themed from `grid_theme` — the same package the desktop resolves against —
/// rather than from a seeded Material scheme. A seed generates a palette that
/// is internally consistent and nothing to do with Grid: it was why this app
/// looked like a different product from the one it is a remote control for.
///
/// Follows the phone's own light/dark setting, which is the platform convention
/// here; the desktop has an in-app picker for it because macOS apps conventionally
/// offer one.
class GridMobileApp extends StatelessWidget {
  const GridMobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Grid',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(brightness: Brightness.light),
    darkTheme: buildAppTheme(brightness: Brightness.dark),
    // Below MaterialApp so it reads the brightness Material actually resolved,
    // which is what the colour tokens resolve against. See _BrightnessSync.
    home: const _BrightnessSync(child: LinkScreen()),
  );
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
