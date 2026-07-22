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
}
