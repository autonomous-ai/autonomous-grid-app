import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/panel_layout.dart';

void main() {
  // A preview panel at its usual docked width, minus the "+" beside the tabs.
  const strip = 420.0;

  test('one tab takes its full width and leaves the strip alone', () {
    expect(tabStripTabWidth(available: strip, count: 1), kTabMaxWidth);
    expect(tabStripScrolls(available: strip, count: 1), isFalse);
  });

  test('tabs share the strip as more open, rather than pushing the + off', () {
    // Four is where the old strip broke: at 180 each they ran to 736px in a
    // 420px row, so the fourth tab and the "+" were both off-screen.
    final width = tabStripTabWidth(available: strip, count: 4);

    expect(width, lessThan(kTabMaxWidth));
    expect(width, greaterThanOrEqualTo(kTabMinWidth));
    expect((width + kTabGap) * 4, lessThanOrEqualTo(strip));
    expect(tabStripScrolls(available: strip, count: 4), isFalse);
  });

  test('they stop shrinking at a width the label still reads at', () {
    // Ten tabs would be 38px each if the floor didn't hold — a chip with room
    // for an icon and nothing else.
    expect(tabStripTabWidth(available: strip, count: 10), kTabMinWidth);
  });

  test('past that floor the row scrolls instead of squeezing further', () {
    expect(tabStripScrolls(available: strip, count: 10), isTrue);
  });

  test('an empty strip asks for nothing and never scrolls', () {
    // The bottom panel draws its strip before its first tab exists; dividing
    // the width by zero tabs must not come back as NaN.
    expect(tabStripTabWidth(available: strip, count: 0), kTabMaxWidth);
    expect(tabStripScrolls(available: strip, count: 0), isFalse);
  });

  test('a strip narrower than one tab degrades instead of throwing', () {
    // The floating panel on a small window, and the moment mid-drag when a
    // seam is being pulled shut.
    expect(tabStripTabWidth(available: 40, count: 3), isNonNegative);
    expect(tabStripScrolls(available: 40, count: 3), isTrue);
  });
}
