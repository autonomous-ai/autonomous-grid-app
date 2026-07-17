import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/liquid_glass.dart';

/// The outer DecoratedBox is the one carrying the shadow — and, after the fix,
/// the border too (so a 1px stroke isn't half-clipped by the ClipRRect).
BoxDecoration _outerDecoration(WidgetTester tester) {
  final boxes = tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(LiquidGlass),
          matching: find.byType(DecoratedBox),
        ),
      )
      .toList();
  // The first DecoratedBox in the tree is the outer one (shadow + border).
  return boxes.first.decoration as BoxDecoration;
}

void main() {
  setUp(() => AppTheme.brightness.value = Brightness.light);

  testWidgets(
    'border is drawn on the outer box (outside the clip) so it is not '
    'shaved to a half-pixel',
    (tester) async {
      const rim = Color(0xFF112233);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LiquidGlass(
                showBorder: true,
                borderColor: rim,
                child: SizedBox(width: 100, height: 40),
              ),
            ),
          ),
        ),
      );

      final deco = _outerDecoration(tester);
      // The outer box carries both the visible border and the lift.
      expect(deco.border, isNotNull);
      expect((deco.border as Border).top.color, rim);
      expect(deco.boxShadow, isNotNull);
    },
  );

  testWidgets('a thicker borderWidth is honoured', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiquidGlass(
              showBorder: true,
              borderWidth: 1.5,
              child: SizedBox(width: 100, height: 40),
            ),
          ),
        ),
      ),
    );

    final deco = _outerDecoration(tester);
    expect((deco.border as Border).top.width, 1.5);
  });

  testWidgets('with no borderColor it falls back to the theme hair', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LiquidGlass(
              showBorder: true,
              child: SizedBox(width: 100, height: 40),
            ),
          ),
        ),
      ),
    );

    final deco = _outerDecoration(tester);
    expect((deco.border as Border).top.color, AppGlass.hair);
  });

  test('the composer lift rim is clearly stronger than the plain hair', () {
    AppTheme.brightness.value = Brightness.light;
    // Alpha is the high byte of the ARGB int; a more opaque rim reads as a
    // visible border instead of vanishing into a white pane.
    expect(AppGlass.lift.a, greaterThan(AppGlass.hair.a));
  });
}
