import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The palette resolves against one global brightness. Everything drawn in the
/// app reads it, so if it ever stopped switching, the whole app would keep
/// whichever theme it started in — and nothing would fail except the screen.
void main() {
  test('color tokens flip with AppTheme.brightness', () {
    AppTheme.brightness.value = Brightness.light;
    final lightBg = AppPalette.windowBg;
    final lightInk = AppPalette.textPrimary;

    AppTheme.brightness.value = Brightness.dark;
    final darkBg = AppPalette.windowBg;
    final darkInk = AppPalette.textPrimary;

    // The window is near-white in light and deep charcoal in dark; the ink
    // inverts to stay legible. If the resolver ever stopped switching, these
    // would be equal.
    expect(lightBg, isNot(equals(darkBg)));
    expect(lightInk, isNot(equals(darkInk)));
    expect(darkBg.computeLuminance(), lessThan(lightBg.computeLuminance()));
    expect(
      darkInk.computeLuminance(),
      greaterThan(lightInk.computeLuminance()),
    );

    // Leave the global back at the shipped default so test order can't leak.
    AppTheme.brightness.value = Brightness.light;
  });

  group('the font settings notifier', () {
    // Every `const` widget in the app rebuilds off this notifier, so a fire on
    // an unchanged setting is a full tree rebuild for nothing.
    setUp(AppFont.reset);
    tearDown(AppFont.reset);

    test('only fires when something actually changed', () {
      var fired = 0;
      void listener() => fired++;
      AppTheme.fonts.addListener(listener);
      addTearDown(() => AppTheme.fonts.removeListener(listener));

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      expect(fired, 1);

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      expect(fired, 1, reason: 'the same settings must not dirty the tree');

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1.2, codeSize: 12.5);
      expect(fired, 2);
    });
  });

  test('the composer lift rim is clearly stronger than the plain hair', () {
    AppTheme.brightness.value = Brightness.light;
    // Alpha is the high byte of the ARGB int; a more opaque rim reads as a
    // visible border instead of vanishing into a white pane.
    expect(AppGlass.lift.a, greaterThan(AppGlass.hair.a));
  });
}
