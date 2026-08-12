import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/panels/panel_metrics.dart';

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

  // The width the same panel is drawn at beside a chat and beside a project.
  // Untested while it lived in the chat pane, and it is the one piece of this
  // that can put a composer below its own floor — where the failure is a row
  // striped yellow and black, not a screen that merely looks tight.
  group('how wide the panel beside the conversation is drawn', () {
    const main = 440.0;

    test('it takes a share of the pane rather than a fixed width', () {
      final size = resolveSidePanel(
        paneWidth: 1400,
        mainMinWidth: main,
        override: null,
      );

      expect(size.fits, isTrue);
      expect(size.width, 1400 * 0.45);
    });

    test('a wide monitor does not open it onto half the world', () {
      final size = resolveSidePanel(
        paneWidth: 3000,
        mainMinWidth: main,
        override: null,
      );

      expect(size.width, kSidePanelMaxWidth);
    });

    test('a drag is not capped by that share, only by what is beside it', () {
      // Past the app's own ceiling on purpose: the user took hold of the seam,
      // so the only thing left to protect is the conversation's floor.
      final size = resolveSidePanel(
        paneWidth: 1400,
        mainMinWidth: main,
        override: 1200,
      );

      expect(size.width, 1400 - main);
    });

    test('it never leaves the conversation under its floor', () {
      final size = resolveSidePanel(
        paneWidth: 900,
        mainMinWidth: main,
        override: 800,
      );

      expect(900 - size.width, greaterThanOrEqualTo(main));
    });

    test('a pane with no room for it says so, and it floats instead', () {
      // Docking here would squeeze the composer; the caller answers with the
      // floating panel, which keeps its full width over the conversation.
      final size = resolveSidePanel(
        paneWidth: 700,
        mainMinWidth: main,
        override: null,
      );

      expect(size.fits, isFalse);
      expect(size.width, greaterThanOrEqualTo(kSidePanelMinWidth));
    });

    test(
      'a pane narrower than the panel itself degrades instead of throwing',
      () {
        // Mid-animation, and on a window dragged smaller than either floor.
        final size = resolveSidePanel(
          paneWidth: 300,
          mainMinWidth: main,
          override: null,
        );

        expect(size.fits, isFalse);
        expect(size.width, isNonNegative);
        expect(size.width, lessThanOrEqualTo(300));
      },
    );
  });
}
