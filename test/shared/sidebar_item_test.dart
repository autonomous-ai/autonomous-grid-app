import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/layouts/widgets/sidebar_item.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 264, child: child),
    ),
  );

  testWidgets('tap fires onTap and the press dip settles back to full size',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        SidebarItem(
          icon: Icons.edit_outlined,
          label: 'New chat',
          onTap: () => taps++,
        ),
      ),
    );

    final rowSize = tester.getSize(find.byType(SidebarItem));

    // Press down — the AnimatedScale should be driving toward 0.97, but the
    // widget's own layout box must not change (scale is a paint transform).
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('New chat')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(find.byType(SidebarItem)), rowSize);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    // Back to rest, still the same box.
    expect(tester.getSize(find.byType(SidebarItem)), rowSize);
  });

  testWidgets('hover drifts the icon without resizing the row', (tester) async {
    await tester.pumpWidget(
      host(
        SidebarItem(
          icon: Icons.edit_outlined,
          label: 'New chat',
          onTap: () {},
        ),
      ),
    );

    final before = tester.getSize(find.byType(SidebarItem));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(SidebarItem))),
    );
    await tester.pumpAndSettle();

    // Hover animates the icon (AnimatedSlide) but the row keeps its size.
    expect(tester.getSize(find.byType(SidebarItem)), before);
    expect(find.byType(AnimatedSlide), findsOneWidget);
  });
}
