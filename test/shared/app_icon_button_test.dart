import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/app_icon_button.dart';

/// Moves a real pointer onto [finder] and settles, so the widget's own
/// MouseRegion fires. `tester.tap` would not — hover is the thing under test.
Future<TestGesture> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pumpAndSettle();
  return gesture;
}

Color _glyphColour(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon)).color!;

Color? _fill(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
  return (box.decoration! as BoxDecoration).color;
}

Future<void> _pump(WidgetTester tester, {VoidCallback? onPressed}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppIconButton(
              icon: Icons.close,
              onPressed: onPressed ?? () {},
            ),
          ),
        ),
      ),
    );

void main() {
  // The bug this widget exists for: a bare IconButton keeps its resting ink
  // while the pointer sits on it, so it reads as decoration rather than an
  // affordance. CLAUDE.md calls this out by name.
  testWidgets('the glyph climbs to textPrimary on hover', (tester) async {
    await _pump(tester);
    expect(_glyphColour(tester), AppPalette.textSecondary);

    await _hover(tester, find.byType(AppIconButton));
    expect(_glyphColour(tester), AppPalette.textPrimary);
  });

  // Colour alone is not enough when the row underneath already lightens on
  // hover — the fill is what separates "on the row" from "on the button".
  testWidgets('a hover fill lands behind the glyph', (tester) async {
    await _pump(tester);
    expect(_fill(tester), Colors.transparent);

    await _hover(tester, find.byType(AppIconButton));
    expect(_fill(tester), AppSurface.hoverFill);
  });

  testWidgets('the ink returns to rest when the pointer leaves', (
    tester,
  ) async {
    await _pump(tester);
    final gesture = await _hover(tester, find.byType(AppIconButton));
    await gesture.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();

    expect(_glyphColour(tester), AppPalette.textSecondary);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('a disabled button neither lifts nor fills', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppIconButton(icon: Icons.close, onPressed: null),
          ),
        ),
      ),
    );
    await _hover(tester, find.byType(AppIconButton));

    expect(_glyphColour(tester), AppPalette.textFaint);
    expect(_fill(tester), Colors.transparent);
  });

  // A destructive button must not cool to neutral grey at the moment it's
  // pressed, so it can override the climb.
  testWidgets('hoverColor overrides the climb', (tester) async {
    const danger = Color(0xFFFF0000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppIconButton(
              icon: Icons.delete_outline,
              hoverColor: danger,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await _hover(tester, find.byType(AppIconButton));
    expect(_glyphColour(tester), danger);
  });

  // A delete button has to say what pressing would *do*, not just where the
  // pointer is — but only in its ink. The fill stays the neutral lift, so the
  // button reads as the same affordance as every other one.
  testWidgets('destructive hover reddens the glyph, not the fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppIconButton(
              icon: Icons.delete_outline,
              destructive: true,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    // Resting stays neutral: a column of red buttons at rest reads as an error
    // state rather than a list.
    expect(_glyphColour(tester), AppPalette.textSecondary);
    expect(_fill(tester), Colors.transparent);

    await _hover(tester, find.byType(AppIconButton));
    expect(_fill(tester), AppSurface.hoverFill);
    expect(_glyphColour(tester), isNot(AppPalette.textPrimary));
    // Red, whichever theme resolved: the light token, or the lightened dark ink
    // that clears 4.5:1 where `colorScheme.error` only reached 3.33.
    final glyph = _glyphColour(tester);
    expect(glyph.r, greaterThan(glyph.g));
    expect(glyph.r, greaterThan(glyph.b));
  });

  // The default must not turn red by accident.
  testWidgets('a non-destructive button keeps the neutral lift', (
    tester,
  ) async {
    await _pump(tester);
    await _hover(tester, find.byType(AppIconButton));
    expect(_fill(tester), AppSurface.hoverFill);
    expect(_glyphColour(tester), AppPalette.textPrimary);
  });

  testWidgets('it still presses', (tester) async {
    var taps = 0;
    await _pump(tester, onPressed: () => taps++);
    await tester.tap(find.byType(AppIconButton));
    expect(taps, 1);
  });
}
