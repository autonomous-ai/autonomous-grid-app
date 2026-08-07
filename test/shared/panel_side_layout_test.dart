import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/widgets/panel_side_layout.dart';

void main() {
  group('resolvePanelSideWidth', () {
    test('follows the panel rather than a fixed number, so the same column is '
        'usable in a narrow panel and not lost in a wide one', () {
      // 30% of 1200 is 360; the app's own share stops at the cap.
      expect(
        resolvePanelSideWidth(panelWidth: 1200, override: null),
        kPanelSideMax,
      );
      expect(
        resolvePanelSideWidth(panelWidth: 700, override: null),
        closeTo(210, 0.001),
      );
      expect(
        resolvePanelSideWidth(panelWidth: 500, override: null),
        kPanelSideMin,
      );
    });

    test('a dragged width may pass the share the app would have picked — the '
        'cap is on what the app chooses, not on what the user asks for', () {
      expect(
        resolvePanelSideWidth(panelWidth: 1000, override: 460),
        460,
        reason: 'well past kPanelSideMax, and the work still has room',
      );
    });

    test('the work keeps its floor however far the seam is dragged', () {
      expect(
        resolvePanelSideWidth(panelWidth: 800, override: 780),
        800 - kPanelMainMin,
      );
    });

    test('and the column keeps its own, so a seam dragged to the edge leaves '
        'something to read rather than a sliver', () {
      expect(
        resolvePanelSideWidth(panelWidth: 800, override: 20),
        kPanelSideMin,
      );
    });

    test(
      'a panel too narrow for both floors degrades instead of throwing — '
      'clamp asserts low <= high, and a panel mid-animation is that narrow',
      () {
        final width = resolvePanelSideWidth(panelWidth: 300, override: null);

        expect(width, isNonNegative);
        expect(width, lessThanOrEqualTo(300));
      },
    );
  });
}
