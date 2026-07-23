import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The Typography section's surfaces, measured rather than looked at.
///
/// The design system's whole point about layering is that the fills are almost
/// identical — page-to-card is 1.105:1 in dark and 1.054:1 in light — so a
/// screenshot cannot tell you whether a block is separated, and a compressed
/// one has already produced false alarms on this project. What can tell you is
/// arithmetic, which is what this file does.
///
/// The values here are the ones the section was built against. If a token moves,
/// these fail and say which pair stopped working, instead of the section quietly
/// going flat in one theme.
void main() {
  tearDown(() => AppTheme.brightness.value = Brightness.light);

  /// WCAG relative luminance.
  double luminance(Color c) {
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// Read tokens as one theme resolves them.
  T inTheme<T>(Brightness brightness, T Function() read) {
    AppTheme.brightness.value = brightness;
    return read();
  }

  group('a settings row separates from the page', () {
    // In dark the fill does some of the work…
    test('dark: the row fill lifts off the page, if only slightly', () {
      final ratio = inTheme(
        Brightness.dark,
        () => contrast(AppPalette.windowBg, AppGlass.surfaceFill),
      );
      expect(ratio, greaterThan(1.15), reason: 'row: $ratio');
    });

    // …and in light it does none at all: both are pure white. That is not a bug
    // to fix by darkening the row — it is why the row must carry a shadow, and
    // why "no borders" only works when the shadow is there. This test exists to
    // stop someone concluding from the 1.000 that the fill needs changing.
    test('light: the fill alone separates nothing — the shadow must', () {
      final ratio = inTheme(
        Brightness.light,
        () => contrast(AppPalette.windowBg, AppGlass.surfaceFill),
      );
      expect(ratio, closeTo(1.0, 0.01), reason: 'row: $ratio');

      final shadow = inTheme(Brightness.light, () => AppGlass.cardShadow);
      expect(
        shadow,
        isNotEmpty,
        reason: 'with an invisible fill, a row with no shadow has no edge',
      );
      expect(
        shadow.any((s) => s.color.a > 0),
        isTrue,
        reason: 'a fully transparent shadow separates nothing',
      );
    });
  });

  group('a control recesses into the row it sits on', () {
    /// What the section actually passes as the field fill.
    Color fieldFill() => AppTheme.pick(AppPalette.cardBg, AppCard.inset);

    for (final brightness in Brightness.values) {
      test('${brightness.name}: the chosen fill beats the alternative', () {
        final (chosen, inset, cardBg) = inTheme(brightness, () {
          final row = AppGlass.surfaceFill;
          return (
            contrast(row, fieldFill()),
            contrast(row, AppCard.inset),
            contrast(row, AppPalette.cardBg),
          );
        });

        expect(
          chosen,
          math.max(inset, cardBg),
          reason:
              'the section picks the *worse* token in ${brightness.name} — '
              'inset $inset vs cardBg $cardBg',
        );
        // Both tokens are close to the row; the point is only that the better
        // one is used. Below ~1.05 a field stops reading as a field at all.
        expect(chosen, greaterThan(1.05), reason: 'field: $chosen');
      });
    }

    // The two themes disagree about which token wins, which is the entire
    // reason the fill is picked at runtime instead of being written once. If
    // this ever stops being true the AppTheme.pick can be simplified — and if
    // someone simplifies it *while* it is true, one theme goes flat.
    test('the two themes really do want different tokens', () {
      final darkWantsInset = inTheme(
        Brightness.dark,
        () =>
            contrast(AppGlass.surfaceFill, AppCard.inset) >
            contrast(AppGlass.surfaceFill, AppPalette.cardBg),
      );
      final lightWantsInset = inTheme(
        Brightness.light,
        () =>
            contrast(AppGlass.surfaceFill, AppCard.inset) >
            contrast(AppGlass.surfaceFill, AppPalette.cardBg),
      );

      expect(darkWantsInset, isTrue);
      expect(lightWantsInset, isFalse);
    });
  });

  group('text on the row stays readable', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}: title and description clear 4.5:1', () {
        final (title, description) = inTheme(brightness, () {
          final row = AppGlass.surfaceFill;
          return (
            contrast(row, AppPalette.textPrimary),
            contrast(row, AppPalette.textSecondary),
          );
        });

        expect(title, greaterThanOrEqualTo(4.5), reason: 'title: $title');
        expect(
          description,
          greaterThanOrEqualTo(4.5),
          reason: 'description: $description',
        );
      });

      // The `px` suffix is a non-essential label on a recessed field — held to
      // the 3:1 UI-component line rather than 4.5:1, and worth pinning because
      // it sits on the *field*, not on the row, and is the lowest-contrast
      // thing in the section.
      test('${brightness.name}: the px suffix clears 3:1 on the field', () {
        final ratio = inTheme(brightness, () {
          final fill = AppTheme.pick(AppPalette.cardBg, AppCard.inset);
          return contrast(fill, AppPalette.textFaint);
        });
        expect(ratio, greaterThanOrEqualTo(3.0), reason: 'px: $ratio');
      });
    }
  });
}
