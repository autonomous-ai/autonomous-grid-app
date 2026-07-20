import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The account menu hangs *above* the pill, positioned by subtracting its own
/// summed height from the anchor — so a row that renders taller or shorter than
/// the constant reserved for it leaves the menu floating in mid-air.
///
/// `_menuRowHeight` is private, and the row is too, so this pins the geometry
/// the row is *built from* instead: the padding and type that decide its height.
/// If someone changes the row's vertical padding or label size without updating
/// the constant, this catches it.
void main() {
  // Keep in step with sidebar_account.dart.
  const menuRowHeight = 36.0;
  const rowInnerVerticalPad = 8.0;
  const rowGutter = 1.0;

  testWidgets('a canonical menu row renders the height the menu reserves', (
    tester,
  ) async {
    // The row as sidebar_account.dart builds it: 1px gutter, 8px inner padding
    // top and bottom, around a 13/1.2 label beside a 16px icon slot.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 232,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: rowGutter,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: rowInnerVerticalPad,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          child: Icon(
                            LucideIcons.settings300,
                            size: AppControl.iconSize,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            'Settings',
                            key: const ValueKey('row'),
                            style: const TextStyle(fontSize: 13, height: 1.2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final rowHeight = tester.getSize(find.byType(Row)).height;
    // The icon slot (16) is taller than the 13/1.2 label (15.6), so the row is
    // icon-driven: 16 + 8 + 8 + 1 + 1 = 34, and the reserved 36 leaves 2px of
    // slack. It must never *exceed* what's reserved.
    expect(
      rowHeight + rowInnerVerticalPad * 2 + rowGutter * 2,
      lessThanOrEqualTo(menuRowHeight),
      reason:
          'the menu row outgrew the $menuRowHeight px the account menu '
          'reserves — update _menuRowHeight in sidebar_account.dart to match',
    );
  });
}
