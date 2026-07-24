import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/presentation/chat_starters.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// The empty state's starter cards, at every UI size the app allows.
///
/// These cards pin their own height — they have to, or four cards with
/// different amounts of text would come out four different heights and the row
/// would look broken. A pinned height around text the widget doesn't measure is
/// exactly the shape that overflows when the type grows, and it did: at 19px the
/// two cards whose titles wrap to two lines ran 10px past their box.
///
/// Rendering overflow is not an exception a test fails on by itself — the app
/// paints a yellow-and-black band and carries on — so this asserts on the
/// error's absence explicitly.
void main() {
  setUp(AppFont.reset);
  tearDown(AppFont.reset);

  Widget host(double uiSize) {
    final scale = uiSize / 14;
    AppTheme.fonts.apply(uiScale: scale, codeSize: 12.5);
    return MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: child ?? const SizedBox.shrink(),
      ),
      home: BrightnessScope(
        child: Scaffold(
          body: ChatStarters(
            greeting: 'What should we create?',
            onPick: (_) {},
          ),
        ),
      ),
    );
  }

  /// Every UI size the settings screen can produce, at the ends and in between.
  const sizes = <double>[11, 12, 14, 16, 17, 18, 19];

  for (final size in sizes) {
    testWidgets('no card overflows at ${size.toInt()}px', (tester) async {
      // A wide window: the cards must fit because they are sized right, not
      // because the pane happened to be roomy. The grid reflows to 2×2 on a
      // narrow one.
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(size));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'a card overflowed at ${size.toInt()}px — its pinned height no '
            'longer holds the type at this scale',
      );
    });
  }

  testWidgets('a card grows with the UI size rather than clipping', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<Size> cardSizeAt(double uiSize) async {
      await tester.pumpWidget(host(uiSize));
      await tester.pumpAndSettle();
      return tester.getSize(
        find
            .ancestor(
              of: find.text('Ask a question'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
    }

    final small = await cardSizeAt(11);
    final big = await cardSizeAt(19);

    expect(big.height, greaterThan(small.height));
    expect(
      big.width,
      greaterThan(small.width),
      reason: 'a fixed width is what wraps the title and overflows the height',
    );
  });

  /// Four cards must land as a 4-up strip or a 2×2 block — never a 3+1 with an
  /// orphan on its own line. That was the Wrap's failure: at a large UI size the
  /// cards grow but the pane doesn't, so the fourth fell to a second row alone.
  /// The number of distinct card y-positions is the number of rows.
  int rowCount(WidgetTester tester) {
    final tops = <double>{};
    for (final title in const [
      'Ask a question',
      'Write something',
      'Understand a document',
      'Plan something',
    ]) {
      tops.add(tester.getRect(find.text(title)).top.roundToDouble());
    }
    return tops.length;
  }

  // The grid must resolve to a 4-up strip or a 2×2 block at every width/size,
  // never a 3+1. NB: this harness stacks uiScale and text-scaling, so a card
  // here is wider than in the running app and the *old* Wrap already came out
  // 2×2 at these widths — i.e. this asserts the new grid's guarantee holds, it
  // does not by itself reproduce the report's 3+1 (that needs the app's real
  // single-scale sizing; verified by hand against a running build). The value
  // is the invariant: whatever the width, the answer is 1 or 2 rows.
  const pairs = <(double width, double uiSize)>[
    (900, 19),
    (760, 19),
    (900, 17.5),
    (1000, 19),
    (620, 19), // narrow: must be a clean 2×2, not a 2+2 that drifts
  ];

  for (final (width, size) in pairs) {
    testWidgets('four cards stay 1–2 rows at ${width.toInt()}×${size}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(size));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final rows = rowCount(tester);
      expect(
        rows == 1 || rows == 2,
        isTrue,
        reason: 'four cards fell into $rows rows at ${width.toInt()}×${size}px',
      );
    });
  }

  // The title is the part that wraps, so it is the part worth measuring: it has
  // to stay inside the card it names at both ends of the range.
  testWidgets('a two-line title stays inside its card', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(19));
    await tester.pumpAndSettle();

    for (final title in const [
      'Ask a question',
      'Write something',
      'Understand a document',
      'Plan something',
    ]) {
      final card = find
          .ancestor(of: find.text(title), matching: find.byType(SizedBox))
          .first;
      final cardRect = tester.getRect(card);
      final titleRect = tester.getRect(find.text(title));

      expect(
        titleRect.bottom,
        lessThanOrEqualTo(cardRect.bottom),
        reason: '"$title" runs past the bottom of its card',
      );
      expect(
        titleRect.right,
        lessThanOrEqualTo(cardRect.right),
        reason: '"$title" runs past the side of its card',
      );
    }
  });
}
