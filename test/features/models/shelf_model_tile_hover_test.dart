import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/model_group.dart';
import 'package:grid_app/features/models/logic/model_shelf.dart';
import 'package:grid_app/features/models/presentation/shelf_model_tile.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/app_icon_button.dart';

ShelfModel _model() {
  const file = LocalModel(
    name: 'Qwen3-0.6B-Q4_K_M.gguf',
    path: '/tmp/models/Qwen3-0.6B-Q4_K_M.gguf',
    sizeBytes: 400000000,
  );
  return ShelfModel(
    name: 'Qwen3-0.6B-Q4_K_M',
    group: ModelGroup(
      displayName: 'Qwen3-0.6B-Q4_K_M.gguf',
      files: const [file],
      primary: file,
      isSplit: false,
    ),
  );
}

Future<TestGesture> _pointer(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        // Room around the row so the pointer has somewhere to be that is
        // *not* on it.
        body: Padding(
          padding: const EdgeInsets.all(80),
          child: Align(
            alignment: Alignment.topCenter,
            child: ShelfModelTile(model: _model()),
          ),
        ),
      ),
    ),
  ),
);

double _deleteOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(AppIconButton),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

Color _deleteGlyph(WidgetTester tester) => tester
    .widget<Icon>(
      find.descendant(
        of: find.byType(AppIconButton),
        matching: find.byType(Icon),
      ),
    )
    .color!;

Color? _deleteFill(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(AppIconButton),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (box.decoration! as BoxDecoration).color;
}

void main() {
  // A destructive control sitting on every row at rest reads as part of the
  // layout and competes with the model's name.
  testWidgets('delete is hidden until the row is hovered', (tester) async {
    await _pump(tester);
    expect(_deleteOpacity(tester), 0);

    final gesture = await _pointer(tester);
    await gesture.moveTo(tester.getCenter(find.byType(ShelfModelTile)));
    await tester.pumpAndSettle();
    expect(_deleteOpacity(tester), 1);
  });

  // The trap CLAUDE.md names: a parent's hover doesn't reach its children. The
  // row revealing the button is one question; the pointer being *on the button*
  // is another, and the button has to answer it itself — otherwise it appears
  // and then sits inert-looking under the very pointer that summoned it.
  testWidgets('hovering the button itself reddens its glyph', (tester) async {
    await _pump(tester);
    final gesture = await _pointer(tester);

    // On the row, but away from the button: revealed, still at rest. Resting
    // stays neutral on purpose — a column of red buttons at rest would read as
    // an error state rather than a list of models.
    final row = tester.getRect(find.byType(ShelfModelTile));
    await gesture.moveTo(Offset(row.left + 20, row.center.dy));
    await tester.pumpAndSettle();
    expect(_deleteOpacity(tester), 1);
    expect(_deleteGlyph(tester), AppPalette.textSecondary);
    expect(_deleteFill(tester), Colors.transparent);

    // Now onto the button: the glyph goes red, the fill stays the neutral lift
    // every other button in the app gets.
    await gesture.moveTo(tester.getCenter(find.byType(AppIconButton)));
    await tester.pumpAndSettle();
    expect(_deleteFill(tester), AppSurface.hoverFill);
    final glyph = _deleteGlyph(tester);
    expect(glyph, isNot(AppPalette.textPrimary));
    expect(glyph.r, greaterThan(glyph.g));
    expect(glyph.r, greaterThan(glyph.b));
  });

  // Opacity, not removal: taking the button out of the tree lets the name and
  // meta stretch into its place and snap back on every pointer cross, so the
  // row twitches as the eye moves down the list.
  testWidgets('the row does not resize when delete appears', (tester) async {
    await _pump(tester);
    final atRest = tester.getRect(find.byType(ShelfModelTile));
    final labelAtRest = tester.getRect(find.text('Qwen3-0.6B-Q4_K_M'));

    final gesture = await _pointer(tester);
    await gesture.moveTo(tester.getCenter(find.byType(ShelfModelTile)));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(ShelfModelTile)), atRest);
    expect(tester.getRect(find.text('Qwen3-0.6B-Q4_K_M')), labelAtRest);
  });

  // An invisible button must not be clickable — an invisible *destructive* one
  // least of all.
  testWidgets('the hidden button cannot be pressed', (tester) async {
    await _pump(tester);
    // `.first` — `find.ancestor` walks outward from the target, so the nearest
    // enclosing IgnorePointer (ours) comes first; the two behind it belong to
    // Material's own scaffolding and both sit at `ignoring: false`. Printed the
    // three rather than reasoning about the order, having guessed it backwards.
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(AppIconButton),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
  });
}
