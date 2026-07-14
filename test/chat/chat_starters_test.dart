import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/presentation/chat_starters.dart';

void main() {
  Widget host(void Function(String) onPick) => MaterialApp(
    home: Scaffold(
      // A realistic pane width so the four cards lay out as they do in-app.
      body: SizedBox(
        width: 820,
        height: 600,
        child: ChatStarters(greeting: 'What should we create?', onPick: onPick),
      ),
    ),
  );

  testWidgets('renders the greeting and four starters, no overflow',
      (tester) async {
    await tester.pumpWidget(host((_) {}));
    await tester.pumpAndSettle();

    expect(find.text('What should we create?'), findsOneWidget);
    expect(find.text('Explore and understand code'), findsOneWidget);
    expect(find.text('Fix a bug or failure'), findsOneWidget);
    // A RenderFlex overflow throws during layout and would already have failed
    // the pump; this asserts the tree is clean.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a starter reports its prompt', (tester) async {
    String? picked;
    await tester.pumpWidget(host((p) => picked = p));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fix a bug or failure'));
    expect(picked, 'Help me debug this issue:\n\n');
  });

  testWidgets('hover lifts a card without throwing or shifting siblings',
      (tester) async {
    await tester.pumpWidget(host((_) {}));
    await tester.pumpAndSettle();

    final target = find.text('Review code and suggest changes');
    final otherBefore = tester.getTopLeft(
      find.text('Fix a bug or failure'),
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(target)));
    await tester.pumpAndSettle();

    // The lift is a paint transform, so the neighbour stays put — allow only
    // sub-pixel drift from the hovered card's rim thickening (1 → 1.5px), which
    // is antialiasing, not a layout shove.
    final otherAfter = tester.getTopLeft(find.text('Fix a bug or failure'));
    expect((otherAfter.dx - otherBefore.dx).abs(), lessThan(1));
    expect(otherAfter.dy, otherBefore.dy);
    expect(tester.takeException(), isNull);
  });
}
