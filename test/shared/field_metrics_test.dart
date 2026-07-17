import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// A text field is a control, so it is [AppControl.height] tall like every other
/// control. Material disagrees: its default field is built for a phone, and
/// between `contentPadding` and the 48px touch target it hands a `prefixIcon`,
/// the grid list's search box rendered 48 tall.
///
/// A metrics test, not a taste test: it catches a Material default quietly
/// reasserting itself on an SDK bump.
///
/// It pins the field against the *token*, not against whatever button happens to
/// sit beside it — an earlier version compared it to the grid header's button,
/// which is deliberately [AppControl.heightSmall] because that row is tight, and
/// so it held the field to the wrong scale.
void main() {
  testWidgets('a search field stands at control height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  style: kFieldTextStyle,
                  decoration: const InputDecoration(
                    hintText: 'Search…',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.getSize(find.byType(TextField)).height;
    expect(
      field,
      closeTo(AppControl.height, 1.0),
      reason:
          'the search field is ${field}px — a control is '
          '${AppControl.height}px, and Material\'s phone-sized default is what '
          'this exists to hold back',
    );
  });
}
