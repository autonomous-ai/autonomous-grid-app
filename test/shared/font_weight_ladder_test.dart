import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The weight ladder, and the split that gives it meaning.
///
/// The app was drawn one step heavier than macOS sets the same things: w600 on
/// every label and w700 on every heading, 170 sites in all. At 13pt that step
/// stops reading as emphasis and starts reading as ink — and because it was on
/// *everything*, nothing was emphasised relative to anything else.
///
/// What matters is not the exact numbers but the ordering: headings must
/// out-rank labels, labels must out-rank body. A change that flattens any of
/// those gaps takes the hierarchy with it.
void main() {
  group('the ladder', () {
    test('has three steps, in order', () {
      expect(AppFont.regular.value, lessThan(AppFont.medium.value));
      expect(AppFont.medium.value, lessThan(AppFont.semibold.value));
    });

    test('is the macOS ladder: regular / medium / semibold', () {
      expect(AppFont.regular, FontWeight.w400);
      expect(AppFont.medium, FontWeight.w500);
      expect(AppFont.semibold, FontWeight.w600);
    });
  });

  group('the text theme splits headings from labels', () {
    final theme = buildAppTheme().textTheme;

    // A heading has to out-rank the medium text beside it. Large sizes also
    // carry weight optically, so dropping these to medium would leave a screen
    // title reading as body copy that happens to be big.
    test('headings and titles stay semibold', () {
      for (final style in [
        theme.headlineLarge,
        theme.headlineMedium,
        theme.headlineSmall,
        theme.titleLarge,
        theme.titleMedium,
      ]) {
        expect(style!.fontWeight, AppFont.semibold);
      }
    });

    // Every `label*` names a control, and 14.5 is where a "title" stops
    // out-ranking anything and becomes a row label.
    test('control labels are medium, not semibold', () {
      for (final style in [
        theme.labelLarge,
        theme.labelMedium,
        theme.labelSmall,
        theme.titleSmall,
      ]) {
        expect(style!.fontWeight, AppFont.medium);
      }
    });

    test('body copy stays regular — it is read, not scanned', () {
      for (final style in [
        theme.bodyLarge,
        theme.bodyMedium,
        theme.bodySmall,
      ]) {
        expect(style!.fontWeight, AppFont.regular);
      }
    });

    // The three tiers have to stay distinct. If a future edit sets labels to
    // the same weight as headings, the ramp above still "passes" each tier's
    // own assertion while the hierarchy is gone — so check the gaps directly.
    test('the three tiers are actually distinct', () {
      final body = theme.bodyMedium!.fontWeight!;
      final label = theme.labelMedium!.fontWeight!;
      final heading = theme.headlineSmall!.fontWeight!;

      expect(body.value, lessThan(label.value));
      expect(label.value, lessThan(heading.value));
    });
  });

  group('the tracking ramp', () {
    // SF Pro is optically sized on Apple's platforms — the system re-spaces it
    // as it scales. Flutter asks CoreText for one static face, so none of that
    // happens for free: every size came out at a flat `letterSpacing: 0`, which
    // is the metric of a mid-size master applied to everything from 12pt to
    // 57pt. Small text read cramped, large headings read as one mass.
    test('opens up small type and tightens large type', () {
      expect(AppFont.trackingFor(11), greaterThan(0));
      expect(AppFont.trackingFor(13), greaterThan(0));
      expect(AppFont.trackingFor(15), 0);
      expect(AppFont.trackingFor(22), lessThan(0));
      expect(AppFont.trackingFor(31), lessThan(0));
    });

    test('never reverses: bigger type is never more tracked out', () {
      const sizes = <double>[11, 12, 13, 14.5, 15, 17, 22, 25, 31, 57];
      for (var i = 1; i < sizes.length; i++) {
        expect(
          AppFont.trackingFor(sizes[i]),
          lessThanOrEqualTo(AppFont.trackingFor(sizes[i - 1])),
          reason: '${sizes[i]}pt is tracked wider than ${sizes[i - 1]}pt',
        );
      }
    });

    // Tracking is not a style knob: at half a pixel it is already the
    // difference between a line that breathes and one that doesn't, and past
    // that it starts to look like a logotype rather than text.
    test('stays within half a pixel either way', () {
      for (final size in <double>[10, 11, 12, 13, 15, 17, 22, 31, 57]) {
        expect(AppFont.trackingFor(size).abs(), lessThanOrEqualTo(0.5));
      }
    });

    test('the text theme takes its tracking from the ramp, not a flat zero', () {
      final theme = buildAppTheme().textTheme;
      expect(theme.labelSmall!.letterSpacing, AppFont.trackingFor(12));
      expect(theme.bodyMedium!.letterSpacing, AppFont.trackingFor(15));
      expect(theme.headlineMedium!.letterSpacing, AppFont.trackingFor(29));
      // The gap is the point: a caption and a headline must not share tracking.
      expect(
        theme.labelSmall!.letterSpacing,
        greaterThan(theme.headlineMedium!.letterSpacing!),
      );
    });
  });

  group('controls', () {
    // Apple sets a push button's label at medium. At 13pt the extra step reads
    // as a button trying to be a heading — and every button in the app takes
    // this one token.
    test('a button label is medium', () {
      expect(AppControl.fontWeight, AppFont.medium);
    });

    test('the themed button style carries that weight, not a default', () {
      // ButtonStyle does not inherit from the text theme, so this is the only
      // thing standing between a button and Material's own w500-ish default.
      final style = buildAppTheme().filledButtonTheme.style!.textStyle!.resolve(
        {},
      )!;
      expect(style.fontWeight, AppControl.fontWeight);
    });
  });
}
